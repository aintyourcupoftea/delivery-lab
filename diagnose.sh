#!/usr/bin/env bash
#
# diagnose.sh <namespace> <deployment>
#
# Read-only evidence collector for a failing Deployment.
#
# Design rules:
#   1. It NEVER mutates cluster state. No rollout restart, no delete, no scale,
#      no patch. Restarting is how you destroy the evidence you came for -
#      crashed containers lose their previous logs and the events age out.
#   2. It gathers in the order a human would actually reason: what is desired,
#      what exists, why the gap, what the app itself said.
#   3. It writes a timestamped bundle so the output can be attached to an
#      incident ticket rather than pasted from a scrollback buffer.
#
set -Eeuo pipefail

NS="${1:-}"
DEPLOY="${2:-}"

if [[ -z "$NS" || -z "$DEPLOY" ]]; then
  echo "usage: $0 <namespace> <deployment>" >&2
  exit 64
fi

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 69; }

OUT="diagnose-${NS}-${DEPLOY}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

# Every command is best-effort: a missing Service or an unschedulable pod must
# not abort collection of everything after it.
run() {
  local label="$1"; shift
  {
    printf '\n===== %s =====\n' "$label"
    printf '$ %s\n\n' "$*"
    "$@" 2>&1 || printf '\n[command exited %s - continuing]\n' "$?"
  } | tee -a "$OUT/report.txt"
}

kubectl get ns "$NS" >/dev/null 2>&1 || { echo "namespace $NS not found" >&2; exit 1; }
kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1 || { echo "deployment $DEPLOY not found in $NS" >&2; exit 1; }

printf 'delivery-lab diagnose | ns=%s deploy=%s | %s\n' "$NS" "$DEPLOY" "$(date -u +%FT%TZ)" | tee "$OUT/report.txt"
run "cluster context" kubectl config current-context

# ---------------------------------------------------------------- 1. intent
# What was asked for, and what does the controller think happened?
run "deployment" kubectl -n "$NS" get deploy "$DEPLOY" -o wide
run "deployment conditions" kubectl -n "$NS" describe deploy "$DEPLOY"
run "rollout status (non-blocking)" kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=10s
run "rollout history" kubectl -n "$NS" rollout history deploy/"$DEPLOY"

# Resolve the Deployment's own selector rather than assuming a label scheme,
# so this script works against any deployment, not just this one.
# shellcheck disable=SC2016  # go-template syntax, must not be shell-expanded
SELECTOR="$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' \
  | sed 's/,$//')"
printf '\nresolved pod selector: %s\n' "$SELECTOR" | tee -a "$OUT/report.txt"

# ReplicaSets show which revision is stuck and whether the old one is still up.
run "replicasets" kubectl -n "$NS" get rs -l "$SELECTOR" -o wide

# ---------------------------------------------------------------- 2. pods
run "pods" kubectl -n "$NS" get pods -l "$SELECTOR" -o wide
# Ready/restart/state columns at a glance - CrashLoopBackOff vs ImagePullBackOff
# vs Running-but-not-Ready are three completely different investigations.
run "pod readiness + restarts" kubectl -n "$NS" get pods -l "$SELECTOR" \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,LASTSTATE:.status.containerStatuses[*].lastState.terminated.reason,EXIT:.status.containerStatuses[*].lastState.terminated.exitCode,NODE:.spec.nodeName'

PODS="$(kubectl -n "$NS" get pods -l "$SELECTOR" -o name || true)"

for POD in $PODS; do
  NAME="${POD#pod/}"
  run "describe $NAME" kubectl -n "$NS" describe "$POD"

  # Probe definitions, in-line, so probe path/port can be compared against the
  # Service targetPort and the port the process actually binds.
  run "probes $NAME" kubectl -n "$NS" get "$POD" \
    -o jsonpath='{range .spec.containers[*]}container={.name}{"\n"}  ports={.ports}{"\n"}  liveness={.livenessProbe}{"\n"}  readiness={.readinessProbe}{"\n"}  startup={.startupProbe}{"\n"}  resources={.resources}{"\n"}{end}'

  run "logs (current) $NAME" kubectl -n "$NS" logs "$POD" --all-containers --tail=200
  # --previous is the whole point during a CrashLoop: the current container has
  # no useful output yet, the one that died does.
  run "logs (previous) $NAME" kubectl -n "$NS" logs "$POD" --all-containers --previous --tail=200
done

# ---------------------------------------------------------------- 3. network
# Service -> Endpoints -> Pod. An empty endpoint list with healthy pods is
# almost always a selector or targetPort mismatch, not an app fault.
run "services in namespace" kubectl -n "$NS" get svc -o wide
for SVC in $(kubectl -n "$NS" get svc -o name || true); do
  run "describe ${SVC#service/}" kubectl -n "$NS" describe "$SVC"
done
run "endpoints" kubectl -n "$NS" get endpoints -o wide
run "endpointslices" kubectl -n "$NS" get endpointslices -o wide

# ---------------------------------------------------------------- 4. events
# Sorted by time, not by resource - OOMKilled, FailedScheduling, Unhealthy and
# BackOff all land here and the ordering is the story.
run "events (time-ordered)" kubectl -n "$NS" get events --sort-by=.lastTimestamp
run "warning events" kubectl -n "$NS" get events --field-selector type=Warning --sort-by=.lastTimestamp

# ---------------------------------------------------------------- 5. capacity
run "resource usage (if metrics-server present)" kubectl -n "$NS" top pods --containers
run "node pressure" kubectl get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MEMPRESSURE:.status.conditions[?(@.type=="MemoryPressure")].status,DISKPRESSURE:.status.conditions[?(@.type=="DiskPressure")].status'

# ---------------------------------------------------------------- 6. policy
run "poddisruptionbudgets" kubectl -n "$NS" get pdb
run "configmaps (names only)" kubectl -n "$NS" get cm
# Secret NAMES only - never the values. A diagnostic bundle gets pasted into
# tickets and chat.
run "secrets (names only, no values)" kubectl -n "$NS" get secrets

printf '\n\nBundle written to: %s/report.txt\n' "$OUT" | tee -a "$OUT/report.txt"
printf 'No resources were modified.\n' | tee -a "$OUT/report.txt"
