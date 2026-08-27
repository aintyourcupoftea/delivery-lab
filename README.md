# delivery-lab

A tiny FastAPI service, containerized, with a local Kubernetes deployment, CI,
and a read-only diagnostic tool.

The task is small on purpose, so this README explains **why** each decision was
made rather than restating what the YAML says.

---

## Contents

```
delivery-lab/
├── README.md
├── app.py                     # sample service (see "Changes to the sample app")
├── requirements.txt           # runtime deps, pinned
├── requirements-dev.txt       # + pytest/httpx
├── Dockerfile                 # multi-stage, non-root, cached deps
├── .dockerignore
├── compose.yaml               # local run: env, healthcheck, restart policy
├── .env.example               # .env is git-ignored
├── diagnose.sh                # read-only evidence collector
├── .kube-linter.yaml
├── .github/workflows/ci.yml
├── k8s/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml        # 2 replicas, probes, limits, rolling update, PDB
│   ├── service.yaml
│   ├── kustomization.yaml
│   └── demos/                 # patch files that reproduce failures A-E
└── tests/
    └── test_app.py
```

---

## Quick start

```bash
# local
cp .env.example .env
docker compose up --build
curl localhost:8080/health/ready

# kubernetes (kind)
kind create cluster --name delivery-lab
docker build -t ghcr.io/OWNER/delivery-lab:1.0.0 .
kind load docker-image ghcr.io/OWNER/delivery-lab:1.0.0 --name delivery-lab
kubectl apply -k k8s/
kubectl -n delivery-lab rollout status deploy/delivery-lab

# diagnose
./diagnose.sh delivery-lab delivery-lab
```

---

## Changes to the sample app

The provided `app.py` was fixed rather than shipped as-is:

| Issue | Fix |
| --- | --- |
| `if name == "main"` | `if __name__ == "__main__"` — the sample never started uvicorn |
| `return {...}` on the same line as an `if` inside `ready()` | separated |
| `requirements.txt` listed only `fastapi` | added `uvicorn`; both pinned |
| No shutdown awareness | SIGTERM starts a lame-duck drain instead of closing the socket |

The shutdown behaviour is the one addition worth reading the code for.

Plain uvicorn closes its listening socket the instant it receives SIGTERM. In
Kubernetes that is a race: endpoint removal and SIGTERM are issued
**concurrently**, so for a moment kube-proxy is still routing to a socket that
has already gone away, and the user gets connection refused — during what is
supposed to be a graceful shutdown.

`GracefulServer` in `app.py` overrides `handle_exit`, so the first SIGTERM:

1. flips `/health/ready` to **503** (liveness stays 200 — a draining pod is
   alive and must not be SIGKILLed mid-drain),
2. keeps serving normally for `DRAIN_SECONDS` (5s) while endpoints and proxies
   deprogram,
3. *then* lets uvicorn drain in-flight requests, up to `GRACEFUL_TIMEOUT` (20s).

A second SIGTERM exits immediately, so shutdown stays interruptible.

Verified locally:

```
ready_before        = 200
SIGTERM received: readiness now 503, draining for 5.0s
ready_after_sigterm = 503
live_after_sigterm  = 200
index_still_served  = 200      <- still serving while draining
exited after        = 5.2s
```

---

## Docker

**Multi-stage.** The builder produces a virtualenv; the runtime stage copies
only that venv. No compiler, no pip cache, no source tree in the final image.

**Dependency caching.** `requirements.txt` is copied and installed *before*
application source. Editing `app.py` re-runs one cheap layer, not the whole
dependency install. A BuildKit `--mount=type=cache` keeps pip's HTTP cache
between builds without ever writing it into a layer.

**Non-root.** A fixed uid/gid 10001 account, `USER 10001:10001`. Numeric rather
than by name so the identity survives a Pod-level `runAsUser` override and
works on hosts where `/etc/passwd` lookups are awkward.

**No secrets.** Nothing sensitive is in `ENV` or `ARG`. Anything needed at build
time would use `RUN --mount=type=secret,id=...`, which exposes the value to a
single `RUN` and never persists it in a layer.

---

## Compose

- Environment comes from `environment:` plus an **optional** `.env`, which is
  git-ignored. Nothing secret is committed.
- The healthcheck deliberately targets `/health/ready`, not `/health/live` —
  Compose has no readiness concept, and `service_healthy` is what dependent
  services wait on locally.
- `restart: unless-stopped` rather than `always`: a container I stopped by hand
  stays stopped across a daemon restart, but crash loops still recover.
- Memory limit mirrors the Kubernetes limit so OOM behaviour is reproducible
  locally.

---

## Kubernetes

| Setting | Value | Reason |
| --- | --- | --- |
| `replicas` | 2 | Brief minimum; survives one pod dying |
| `maxUnavailable` | 0 | Capacity never drops below 2 mid-rollout |
| `maxSurge` | 1 | One extra pod at a time; bounded blast radius |
| `minReadySeconds` | 10 | A pod that passes readiness then immediately crashes does not count as a successful step |
| `progressDeadlineSeconds` | 300 | The thing that makes `rollout status` *fail* instead of hanging |
| `requests` == `limits` (memory) | 128Mi | Guaranteed QoS — evicted last under node memory pressure |
| `terminationGracePeriodSeconds` | 45 | > 5s preStop + 20s drain + headroom |
| PodDisruptionBudget | `minAvailable: 1` | Node drains cannot take both replicas |

**Probes.** Three of them, doing three different jobs:

- `startupProbe` → *has it finished booting?* Guards the other two, so liveness
  can stay aggressive without killing a slow start.
- `livenessProbe` → *is this process wedged?* No dependencies, no shutdown
  awareness. Failing it means **restart**, so it must only test things a restart
  can fix.
- `readinessProbe` → *should this pod get traffic right now?* Failing it removes
  the pod from endpoints. Nothing restarts.

**Graceful termination.** Endpoint removal and `preStop` start *concurrently* —
the classic race. Two things cover it: a 5s `preStop` sleep before SIGTERM is
sent, and the application's own 5s lame-duck drain after it. Belt and braces,
because `preStop` alone does not help a connection that was already in flight,
and the app-side drain alone does not help a proxy that ignores readiness.

```
t=0    Terminating; endpoint removal + preStop start concurrently
t=0-5  preStop sleep -> proxies deprogram
t=5    SIGTERM -> readiness 503, still serving (DRAIN_SECONDS=5)
t=10   uvicorn drains in-flight requests (GRACEFUL_TIMEOUT=20)
t=45   SIGKILL if still alive
```

**Config changes.** `checksum/config` in the pod template annotations is
recomputed by CI. Without it, editing a ConfigMap consumed via `envFrom` changes
nothing in running pods, because env is read once at startup.

---

## CI (`.github/workflows/ci.yml`)

Pipeline: **test → scan → build → deploy (gated) → verify**.

- Uses `pull_request`, **not** `pull_request_target`. Fork PRs run
  untrusted code with a read-only token and no secrets.
- `permissions: contents: read` at the workflow level; each job widens only what
  it needs.
- Security/config checks: `gitleaks` (committed secrets), `hadolint`
  (Dockerfile), `trivy` (image CVEs, fixable HIGH/CRITICAL only), `kubeconform`
  (schema), `kube-linter` (policy — probes, limits, non-root, selector match).
- **No static cloud keys.** Deploy authenticates via GitHub OIDC → GCP Workload
  Identity Federation. GitHub mints a short-lived token for the job; GCP's trust
  policy is pinned to this repo *and* this ref and exchanges it for a ~1h
  credential. The only stored values are non-secret identifiers in
  `vars.*`. Same pattern on AWS (`sts:AssumeRoleWithWebIdentity`) or Azure
  (federated credentials).
- Images deploy **by digest**, not tag — a tag can be moved after it is scanned.
- The deploy job is gated behind a GitHub Environment with required reviewers.
- Verification is two steps: `rollout status --timeout=6m`, then a smoke test
  *through the Service* — because rollout status only proves pods are Ready, not
  that Service → Endpoints → Pod actually resolves.

---

## `diagnose.sh`

```
./diagnose.sh <namespace> <deployment>
```

Collects, in the order a human would reason:

1. Deployment intent, conditions, rollout status/history, ReplicaSets
2. Pods: phase, ready, restart counts, `lastState.terminated.reason` + exit code
3. `describe` per pod, probe definitions inline, current logs **and
   `--previous` logs**
4. Service → Endpoints → EndpointSlices
5. Events, time-ordered, plus a warnings-only view
6. `top pods`, node pressure conditions, PDBs, ConfigMap and Secret **names**

Design rules it follows:

- **It never mutates anything.** No restart, no delete, no scale, no patch.
  Restarting a crashed pod destroys exactly the evidence you came for: the
  previous container's logs and the events that are about to age out.
- Every command is best-effort — a missing Service must not abort collection.
- Secret *names* only, never values; the bundle gets pasted into tickets.
- Output goes to a timestamped directory so it can be attached to an incident.

---

## Failure demonstrations

Patch files for each of these live in `k8s/demos/`.

### A. Not ready (`READY=false`)

**Expected:**

```
NAME                            READY   STATUS    RESTARTS
delivery-lab-6c9f... 0/1     Running   0
```

- Pods stay `Running`, `READY 0/1`, restart count stays **0** — readiness
  failure does not restart anything.
- `kubectl get endpoints delivery-lab` → `<none>`.
- Events show `Warning Unhealthy ... Readiness probe failed: HTTP probe failed
  with statuscode: 503`.
- Users get connection refused / 503 from the Service, because it has zero
  backends.
- During a *rollout*, with `maxUnavailable: 0`, this is safe: the old
  ReplicaSet keeps serving and the rollout simply stalls.

### B. Slow request (`WORK_DELAY=5`)

**Expected:**

- `/work` takes 5s. Probes hit `/health/live` and `/health/ready`, which are
  unaffected, so **the pod stays Ready the whole time**.
- Kubernetes reports a perfectly healthy Deployment while every user request is
  5 seconds slow. This is the "Kubernetes-healthy but user-unhealthy" case.
- Nothing in `kubectl get pods` will ever show this. It is only visible in
  request-latency metrics (p95/p99) and access logs.
- What would actually catch it: an SLO on request latency, not a probe. Adding
  the slow path to readiness would be *worse* — it would pull healthy pods out
  of rotation and concentrate the same load on fewer of them.

### C. Bad container port

Application listens on 9090; `containerPort`, probes and Service `targetPort`
all say 8080.

**Expected:**

- The container starts fine and logs `Uvicorn running on http://0.0.0.0:9090`.
  The process is healthy — nothing in the logs indicates a problem.
- `startupProbe` fails: `Warning Unhealthy ... Startup probe failed: dial tcp
  10.244.0.7:8080: connect: connection refused`.
- After `failureThreshold: 30` the kubelet kills the container →
  `CrashLoopBackOff`, restart count climbing.
- Endpoints stay empty. New rollout stalls; old pods keep serving.
- **How to tell it apart from an app crash:** the container exits by kubelet
  kill, not by its own error. `kubectl logs --previous` shows a *cleanly
  started* server, and `lastState.terminated.reason` is `Error` from the probe
  kill rather than a traceback. The give-away is `connection refused` on the
  probe while the app logs a successful bind — compare the port in
  `.spec.containers[].ports` against what the process actually printed.
- Note `targetPort: http` (named) in the Service means the Service and the
  container port can never disagree — the numeric port lives in exactly one
  place. That eliminates half of this class of bug by construction.

### D. Memory pressure

The container exceeds its 128Mi limit.

**Evidence I would expect:**

- `kubectl get pod -o jsonpath='{...lastState.terminated}'` →
  `reason: OOMKilled`, `exitCode: 137` (128 + SIGKILL 9).
- Restart count increments; status cycles
  `Running → OOMKilled → CrashLoopBackOff` if it recurs.
- **`kubectl logs --previous` will show no error and no traceback** — the
  cgroup OOM killer sends SIGKILL, which cannot be caught or logged. Truncated,
  unremarkable logs ending mid-work are themselves the signal.
- `kubectl describe pod` → `Last State: Terminated, Reason: OOMKilled`.
- Node-level `dmesg` / kernel log: `Memory cgroup out of memory: Killed process
  ... (python)`.
- `kubectl top pod` showing usage pinned at the limit right before the kill.
- Because requests == limits (Guaranteed QoS), this is a **container** OOM
  against its own cgroup, not node-level eviction. The distinction matters:
  eviction would show a `Failed`/`Evicted` pod and a node `MemoryPressure`
  condition instead, and would mean the node is oversubscribed rather than the
  app being over its budget.
- What I would *not* conclude immediately: that the limit is too low. First
  question is whether it is a leak (usage climbing monotonically across the
  restart cycle) or a genuine working-set change.

### E. Bad rollout (never becomes ready)

Deploy `1.1.0-broken` with `READY=false`.

**How CI detects it:**
`kubectl rollout status deploy/delivery-lab --timeout=6m` returns non-zero once
the Deployment trips `progressDeadlineSeconds: 300` and sets
`Progressing=False / ProgressDeadlineExceeded`. Without that field the command
would block until the job timed out with a much less useful signal. The
smoke test through the Service is the second gate.

**What users experience: nothing.** With `maxUnavailable: 0` and `maxSurge: 1`,
the new pod never becomes Ready, so it is never added to endpoints; the two old
pods keep serving 100% of traffic. The rollout is stuck, not broken. That is the
whole point of the strategy — a bad deploy costs deploy velocity, not
availability.

**Recovery:**

```bash
kubectl -n delivery-lab rollout undo deploy/delivery-lab
kubectl -n delivery-lab rollout status deploy/delivery-lab
```

Then `./diagnose.sh delivery-lab delivery-lab` **before** cleaning up the failed
ReplicaSet, since undoing does not delete it and its pods still hold the
evidence.

I deliberately did **not** wire automatic rollback into CI. See the last README
question below.

---

## README questions

**What should liveness test that readiness should not?**

Liveness should test only conditions a **restart can fix**: a deadlocked event
loop, an exhausted thread pool, a wedged process. Nothing external. Readiness is
where dependency state belongs, because failing it removes traffic without
killing anything. Concretely: readiness may check "can I reach Postgres";
liveness must not. Liveness should also stay green during graceful shutdown —
a draining pod is alive and must not be SIGKILLed mid-drain.

**Why do Kubernetes requests affect scheduling?**

The scheduler places pods using **requests**, not limits and not actual usage.
It sums the requests of pods already assigned to each node and only fits a pod
where `allocatable - sum(requests) >= request`. Limits are a runtime cgroup
ceiling and are invisible to scheduling. Two consequences: requests set far
above real usage waste capacity across the whole cluster, and requests set far
below it let the scheduler overcommit a node into CPU throttling and OOM kills.
Requests also determine QoS class — `requests == limits` gives Guaranteed, which
is evicted last under node pressure.

**How can a rollout be Kubernetes-healthy but user-unhealthy?**

Because Kubernetes only knows what the probes tell it, and the probes are a
liveness/readiness endpoint, not the user's request path. Failure B is the exact
demonstration: `WORK_DELAY=5` makes every real request 5s slow while
`/health/*` answers instantly, so the Deployment reports 2/2 Ready and the
rollout succeeds. The same happens with a version that returns HTTP 200 with
wrong data, a config change that points at an empty database, or a pod whose
p99 latency triples under real traffic that a probe never applies. Green
`rollout status` means "the pods say they are fine", not "users are fine". The
gap is closed with SLO-based verification after the rollout — error rate and
latency from real traffic, ideally with a canary stage — not with more probes.

**How would you authenticate CI to a cloud provider without static keys?**

OIDC workload identity federation. The CI platform mints a short-lived,
audience-scoped JWT describing the job (repo, ref, workflow, environment); the
cloud provider verifies it against the platform's public JWKS and exchanges it
for a short-lived credential — GCP Workload Identity Federation, AWS
`sts:AssumeRoleWithWebIdentity`, Azure federated credentials. The trust policy
must pin **both** the repository and the ref/environment; trusting `repo:org/*`
or omitting the subject condition means any branch or any repo in the org can
assume the role. No long-lived key exists, so there is nothing to leak, rotate,
or find in a build log. This repo does that in the `deploy` job — the only
stored values are non-secret identifiers in `vars.*`.

**What is one dangerous Terraform/state mistake you would prevent in
production?**

Unlocked or local state. State in a local file or an unlocked backend means two
concurrent applies interleave and corrupt it, and a lost state file makes
Terraform believe live infrastructure does not exist — the next apply tries to
*create* what already exists, or, worse, a mismatched state makes it destroy
and recreate a database. The fix: a remote backend with locking and versioning
(GCS/S3 with object versioning, native state locking), separate state per
environment, and `prevent_destroy` on stateful resources. I would also require
plan review in CI with the plan artifact applied verbatim, so what was reviewed
is what runs — and never `terraform apply -auto-approve` against prod from a
job that can also run on a PR branch.

**What metrics/logs would you want before allowing automatic rollback?**

Automatic rollback is a control loop, and a control loop firing on a bad signal
is worse than no loop at all. Before enabling it I would want:

- Request **error rate** and **latency** (p50/p95/p99) split by version, from
  the serving path — not from probes.
- Enough traffic on the new version for those numbers to be statistically
  meaningful; a canary at 5% for 60 seconds on a low-traffic service tells you
  nothing.
- A baseline comparison against the previous version over the same window, not
  a fixed threshold — thresholds fire on normal traffic spikes.
- Saturation signals: restart counts, OOM kills, CPU throttling.
- Confirmation that the rollback is genuinely safe: **an irreversible database
  migration makes automatic rollback dangerous**, so schema changes must be
  backward-compatible (expand/contract) before this is switched on.
- A cap on rollback frequency and an alert on every firing, so a flapping loop
  cannot silently ping-pong between two versions.

**What would you change if this service handled 10x traffic?**

- Run uvicorn with multiple workers or scale out horizontally, and add an
  **HPA** driven by a real signal (RPS or latency) rather than CPU alone.
- Right-size requests/limits from observed p95 usage; likely raise the CPU
  request so the scheduler stops packing nodes.
- Add connection-level protection: timeouts, bounded concurrency, and a queue
  limit so `/work` sheds load rather than piling up and OOMing.
- Put the metrics in place first — RED metrics + an SLO — because at 10x, the
  failure mode is B (slow and healthy), not A (obviously down).
- Consider a canary/progressive rollout (Argo Rollouts / Flagger) so a bad
  version meets 1% of traffic, not 100%.
- `PodDisruptionBudget` becomes load-bearing during node upgrades; revisit
  `minAvailable` as a percentage.

**What shortcut did you intentionally take?**

Several, consciously:

1. **No real cluster was used.** Manifests are validated with `kubeconform` and
   `kube-linter`, and the failure behaviours are documented from how these
   controllers work, not from a recorded run. Given more time I would ship a
   `kind` GitHub Actions job that actually reproduces A–E and asserts the
   output.
2. **No Secret and no external dependency.** The service has none, so the
   secrets story is described (build-time `--mount=type=secret`, runtime
   External Secrets) rather than implemented.
3. **`sleep 5` as a `preStop` hook** — it needs a shell in the image. A
   `preStop` `httpGet` or the newer sidecar/`terminationGracePeriod` handling
   avoids that; the sleep is the version that works on every Kubernetes version.
4. **Single environment.** A real setup would have kustomize overlays per
   environment rather than one base with CI-side `sed`/`kustomize edit`.
5. **No image signing verification at admission.** CI signs (`provenance`,
   `sbom`), but nothing enforces the signature at deploy time; that needs a
   policy controller (Kyverno/Gatekeeper) the brief did not ask for.
6. **No NetworkPolicy.** A default-deny with explicit egress would be table
   stakes in production.
