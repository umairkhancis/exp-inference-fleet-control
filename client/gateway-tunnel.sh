#!/usr/bin/env bash
#
# gateway-tunnel.sh — make a fleet gateway reachable from the mac.
#
# The gateway's LoadBalancer IP comes from MetalLB inside the VM's docker
# network (192.168.49.0/24), which the mac has no route into. This
# port-forwards the gateway's Envoy service to localhost instead.
#
# Usage:
#   ./gateway-tunnel.sh                          # inference-cluster-1 -> :8080
#   ./gateway-tunnel.sh inference-cluster-2 8081

set -euo pipefail

CONTEXT="${1:-inference-cluster-1}"
PORT="${2:-8080}"

SVC=$(kubectl --context "$CONTEXT" get svc -n envoy-gateway-system -o name \
  | grep 'envoy-modelplane-system-inference-gateway' | head -1)
[ -n "$SVC" ] || { echo "ERROR: no inference-gateway Envoy service on $CONTEXT" >&2; exit 1; }

echo "Gateway of $CONTEXT -> http://localhost:$PORT  (Ctrl-C to stop)"
exec kubectl --context "$CONTEXT" -n envoy-gateway-system \
  port-forward "$SVC" "$PORT:80"
