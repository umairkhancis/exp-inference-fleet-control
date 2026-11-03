#!/usr/bin/env bash
#
# fleet-start.sh — bring the parked PoC fleet back to a serving state.
#
# A plain `multipass start` restores the VMs, but two things need a nudge
# after every reboot (learned the hard way):
#
#   1. minikube's MetalLB addon resets its ConfigMap to an empty template
#      on boot, silently killing the gateway LoadBalancer IPs — so the
#      address pools are re-applied here.
#   2. The engine pod occasionally comes back with CreateContainerError
#      ("claim ... is not prepared by this driver") from stale DRA state —
#      recycling the pod fixes it.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONTROL_CONTEXT="${CONTROL_CONTEXT:-modelplane}"
CLUSTERS=(inference-cluster-1 inference-cluster-2)
WORKLOAD_CLUSTER="inference-cluster-1"   # where the model replica lives
GATEWAY_IP="192.168.49.100"

log() { printf '\n==> %s\n' "$*"; }

# ------------------------------------------------------------ 1. start VMs --
for vm in "$CONTROL_CONTEXT" "${CLUSTERS[@]}"; do
  log "Starting $vm"
  multipass start "$vm"
done

# ------------------------------------------------- 2. wait for cluster APIs -
for ctx in "$CONTROL_CONTEXT" "${CLUSTERS[@]}"; do
  log "Waiting for $ctx API server"
  for _ in $(seq 1 60); do
    kubectl --context "$ctx" get nodes --request-timeout=10s >/dev/null 2>&1 && break
    sleep 10
  done
  kubectl --context "$ctx" get nodes --request-timeout=15s >/dev/null \
    || { echo "ERROR: $ctx API did not come back within 10m." >&2; exit 1; }
done

# --------------------------------- 3. re-apply MetalLB pools (reset on boot) -
for cluster in "${CLUSTERS[@]}"; do
  log "Re-applying MetalLB address pool on $cluster"
  manifest=$(find "$REPO_ROOT/manifests" -path "*/$cluster/metallb-config.yaml" | head -1)
  kubectl --context "$cluster" apply -f "$manifest"
done

# ------------------------------- 4. engine pod: recycle if DRA state is stale
NS=$(kubectl --context "$WORKLOAD_CLUSTER" get ns -o name 2>/dev/null \
  | grep -o 'mp-ml-team-[0-9]*' | head -1 || true)
if [ -n "$NS" ]; then
  log "Checking engine pod in $WORKLOAD_CLUSTER/$NS (up to 5m)"
  for _ in $(seq 1 20); do
    STATUS=$(kubectl --context "$WORKLOAD_CLUSTER" get pods -n "$NS" --no-headers \
      --request-timeout=15s 2>/dev/null | grep -- '-qwen-' | grep -v Terminating || true)
    echo "    $STATUS"
    echo "$STATUS" | grep -q '1/1' && break
    if echo "$STATUS" | grep -qE 'CreateContainerError|CrashLoopBackOff'; then
      POD=$(echo "$STATUS" | awk '{print $1}' | head -1)
      log "Recycling $POD (stale DRA claim after reboot)"
      kubectl --context "$WORKLOAD_CLUSTER" delete pod -n "$NS" "$POD" \
        --request-timeout=30s --wait=false || true
    fi
    sleep 15
  done
fi

# ------------------------------------------------------------ 5. smoke test -
log "Smoke-testing gateway at $GATEWAY_IP (first request after a pod swap can 500 — retrying)"
for i in $(seq 1 10); do
  CODE=$(multipass exec "$WORKLOAD_CLUSTER" -- curl -s -m 10 -o /dev/null \
    -w '%{http_code}' "http://$GATEWAY_IP/v1/models" || echo 000)
  echo "    try $i: HTTP $CODE"
  [ "$CODE" = "200" ] && break
  sleep 10
done

log "Fleet status:"
kubectl --context "$CONTROL_CONTEXT" get inferencecluster,inferencegateway
echo
echo "Test a completion from inside the VM:"
echo "  multipass exec $WORKLOAD_CLUSTER -- curl -s http://$GATEWAY_IP/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"ml-team/qwen-cpu\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":30}'"
