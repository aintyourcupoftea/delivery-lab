# delivery-lab

A small FastAPI service, containerised, with a local Kubernetes deployment, CI,
and a read-only diagnostic script.

The task is small on purpose, so this README explains why each decision was made
instead of repeating what the YAML already says. The answers to the written
questions are first, since those are the main thing being asked for. Everything
after that is the walkthrough of the setup itself.

---

## Answers

**What should liveness test that readiness should not?**

Liveness should check only the things a restart can actually fix. A stuck event
loop, a blocked thread pool, a process that has wedged itself. It should not
check the database or any other service. If Postgres is down, restarting this
pod does not bring Postgres back. It just removes a pod that was working fine.

Dependency checks belong in readiness. When readiness fails the pod is taken
out of the Service endpoints, but the process keeps running. Traffic stops
going there and the pod can recover on its own.

One more case that is easy to miss. Liveness must stay green while the pod is
shutting down. A draining pod is still alive. If liveness starts failing during
the drain, the kubelet kills it while it is still finishing requests.

**Why do Kubernetes requests affect scheduling?**

The scheduler places pods using requests. It adds up the requests of the pods
already on a node and checks whether the new pod still fits in what is left.
Limits do not take part in this. A limit is only a runtime ceiling on the
cgroup.

So the number you put in requests decides node packing. Set it too high and
nodes look full when they are mostly idle, and you pay for capacity nobody
uses. Set it too low and the scheduler puts too many pods on one node. Then
they fight over CPU and get throttled, or the node runs out of memory and
starts killing things.

Requests also decide the QoS class. When requests equal limits the pod is
Guaranteed, and it is the last one evicted when the node is under pressure.

**How can a rollout be Kubernetes-healthy but user-unhealthy?**

Kubernetes only knows what the probes tell it, and the probe hits a health
endpoint, not the real request path.

Demo B in this repo is exactly this. With `WORK_DELAY=5` every real request
takes five seconds, but `/health/ready` still answers instantly. The Deployment
shows 2/2 Ready, `rollout status` returns success, and every user is sitting
there waiting five seconds.

The same thing happens when a new version returns HTTP 200 with wrong data,
when a config change points it at an empty database, or when the code is only
slow under real load that a probe never produces.

A green rollout means the pods say they are fine. It does not mean users are
fine. The way to close that gap is to check error rate and latency from real
traffic after the deploy, ideally through a canary. Adding more probes does not
help.

**How would you authenticate CI to a cloud provider without static keys?**

OIDC federation. GitHub mints a short-lived token for the job that describes
where it came from: repository, ref, workflow, environment. The cloud provider
verifies that token against GitHub's public keys and exchanges it for a
short-lived credential. On GCP this is Workload Identity Federation, on AWS it
is `sts:AssumeRoleWithWebIdentity`, and Azure has federated credentials.

The part that matters is the trust policy on the cloud side. Pin both the
repository and the ref or environment. If you trust `repo:org/*`, then any
repository in the org can get that credential. If you leave out the subject
condition, any branch can.

Nothing long-lived is stored anywhere, so there is no key to leak, rotate, or
accidentally print in a build log. The `deploy` job here works this way. The
only stored values are `vars.*`, and those are plain identifiers, not secrets.

**What is one dangerous Terraform/state mistake you would prevent in production?**

Local or unlocked state.

If state sits in a local file, or in a backend with no locking, two applies
running at the same time will corrupt it. And if the state file is lost,
Terraform no longer knows the infrastructure exists. The next apply tries to
create resources that are already there, or it decides the database needs to be
destroyed and recreated.

What I would put in place: a remote backend with locking and versioning,
separate state per environment, and `prevent_destroy` on stateful resources.
Run `plan` in CI, have a person review it, then apply that same saved plan file
so what was reviewed is what runs. And never `terraform apply -auto-approve`
against production from a job that can also be triggered on a PR branch.

**What metrics/logs would you want before allowing automatic rollback?**

Automatic rollback is a control loop. If it runs on a bad signal it does more
damage than having no rollback at all. Before switching it on I would want:

- Error rate and latency (p50, p95, p99) split by version, measured on the
  serving path and not from probes.
- Enough traffic on the new version for those numbers to mean something. Five
  percent of traffic for sixty seconds on a quiet service tells you nothing.
- A comparison against the previous version over the same window, rather than a
  fixed threshold. Fixed thresholds fire during normal traffic spikes.
- Saturation signals: restart counts, OOM kills, CPU throttling.
- Confirmation that rolling back is actually safe. If a database migration
  cannot be reversed, automatic rollback is dangerous. Schema changes need to
  be backward compatible first, using expand and contract.
- A cap on how often rollback can fire and an alert every time it does, so it
  cannot quietly flip between two versions all day without anyone noticing.

**What changes would you make if this service handled 10x traffic?**

- Run uvicorn with more workers and scale out horizontally. Add an HPA driven
  by requests per second or latency, not CPU alone.
- Set requests and limits from observed p95 usage instead of a guess. The CPU
  request would most likely go up so the scheduler stops packing nodes so
  tightly.
- Add timeouts, a concurrency limit, and a queue limit, so `/work` sheds load
  instead of piling up until the pod is OOM killed.
- Get metrics and an SLO in place first. At 10x the failure you actually meet
  is demo B, slow but healthy, not demo A where the pod is obviously down.
- Move to a progressive rollout with Argo Rollouts or Flagger, so a bad version
  reaches one percent of users instead of all of them.
- Revisit the PodDisruptionBudget. It starts to matter during node upgrades,
  and `minAvailable` is better expressed as a percentage.

**What shortcut did you intentionally take?**

A few, all on purpose:

1. No real cluster. The manifests are validated with `kubeconform` and
   `kube-linter`, and the failure cases are written from how these controllers
   behave, not from a recorded run. With more time I would add a `kind` job in
   CI that reproduces A to E and asserts the output.
2. No Secret and no external dependency. The service does not have one, so the
   secrets story is described (`--mount=type=secret` at build time, External
   Secrets at runtime) instead of implemented.
3. `preStop` uses `sleep 5`, which needs a shell in the image. A `preStop`
   `httpGet` is cleaner, but the sleep works on every Kubernetes version.
4. One environment only. A real setup would use kustomize overlays per
   environment instead of a single base patched by CI.
5. CI signs the image (provenance, SBOM) but nothing verifies that signature at
   deploy time. That needs a policy controller like Kyverno or Gatekeeper,
   which the task did not ask for.
6. No NetworkPolicy. A default-deny with explicit egress would be normal in
   production.

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
docker build -t ghcr.io/aintyourcupoftea/delivery-lab:1.0.0 .
kind load docker-image ghcr.io/aintyourcupoftea/delivery-lab:1.0.0 --name delivery-lab
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

I deliberately did not wire automatic rollback into CI. See the last question
at the top of this README.
