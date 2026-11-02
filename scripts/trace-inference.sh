#!/usr/bin/env bash
#
# trace-inference.sh
#
# Sends one chat completion through the fleet and collects proof of every
# hop it crossed:
#
#   client (inside the VM)
#     -> Envoy gateway (LoadBalancer IP from MetalLB)      [access log]
#     -> endpoint picker (EPP chooses a model replica)     [EPP log]
#     -> vLLM engine pod (runs the model)                  [engine log + metrics]
#     -> response (JSON echoes the served model + token usage)
#
# A unique X-Request-Id header ties the hops together; vLLM's Prometheus
# counters give before/after proof that THIS request was served.
#
# Usage:
#   ./trace-inference.sh [cluster-name] [gateway-name] [model-name]
#   defaults: inference-cluster-1 public ml-team/qwen-cpu

set -euo pipefail

CLUSTER="${1:-inference-cluster-1}"
GATEWAY="${2:-public}"
MODEL="${3:-ml-team/qwen-cpu}"
CONTROL_CONTEXT="${CONTROL_CONTEXT:-modelplane}"
REQ_ID="trace-$(date +%s)-$RANDOM"

log() { printf '\n==> %s\n' "$*"; }

# -------------------------------------------------- 0. fleet-level facts ----
log "Control plane: where is the model running?"
kubectl --context "$CONTROL_CONTEXT" get modelreplica -n "${MODEL%%/*}" \
  -o custom-columns='REPLICA:.metadata.name,CLUSTER:.spec.clusterName,SERVING:.status.conditions[?(@.type=="ModelServing")].status'

ADDRESS=$(kubectl --context "$CONTROL_CONTEXT" get ig "$GATEWAY" -o jsonpath='{.status.endpoints.openAI}')
log "Gateway OpenAI endpoint: $ADDRESS"

# Workload namespace + pods on the inference cluster.
NS=$(kubectl --context "$CLUSTER" get ns -o name | grep "mp-${MODEL%%/*}-" | head -1 | cut -d/ -f2)
ENGINE_POD=$(kubectl --context "$CLUSTER" get pods -n "$NS" --no-headers | grep -v epp | grep Running | awk '{print $1}' | head -1)
EPP_POD=$(kubectl --context "$CLUSTER" get pods -n "$NS" --no-headers | grep epp | awk '{print $1}' | head -1)
log "Engine pod: $NS/$ENGINE_POD   EPP pod: $NS/$EPP_POD"

# ------------------------------------------- 1. metrics BEFORE the request --
BEFORE=$(kubectl --context "$CLUSTER" exec -n "$NS" "$ENGINE_POD" -c engine -- \
  sh -c "wget -qO- http://localhost:8000/metrics 2>/dev/null || curl -s http://localhost:8000/metrics" \
  | grep '^vllm:request_success_total' || echo "vllm:request_success_total 0")
log "vLLM success counter BEFORE: $BEFORE"

# ------------------------------------------------------ 2. the request ------
log "Sending request through the gateway (X-Request-Id: $REQ_ID)"
multipass exec "$CLUSTER" -- curl -sS -D /tmp/trace-headers.txt \
  "$ADDRESS/chat/completions" \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: $REQ_ID" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: fleet test OK\"}],\"max_tokens\":20}" \
  | tee /tmp/trace-response.json
echo
log "Response headers from the gateway:"
multipass exec "$CLUSTER" -- cat /tmp/trace-headers.txt

# -------------------------------------------- 3. metrics AFTER the request --
AFTER=$(kubectl --context "$CLUSTER" exec -n "$NS" "$ENGINE_POD" -c engine -- \
  sh -c "wget -qO- http://localhost:8000/metrics 2>/dev/null || curl -s http://localhost:8000/metrics" \
  | grep '^vllm:request_success_total' || true)
log "vLLM success counter AFTER:  $AFTER"

# ------------------------------------------------- 4. per-hop log proof -----
log "Hop 1 — Envoy gateway access log (request id $REQ_ID):"
kubectl --context "$CLUSTER" logs -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=inference-gateway --tail=200 2>/dev/null \
  | grep -i "$REQ_ID" || echo "  (no match by id — showing last access-log line)" \
  && kubectl --context "$CLUSTER" logs -n envoy-gateway-system \
    -l gateway.envoyproxy.io/owning-gateway-name=inference-gateway --tail=1 2>/dev/null

log "Hop 2 — endpoint picker (EPP) log:"
kubectl --context "$CLUSTER" logs -n "$NS" "$EPP_POD" --tail=20 | tail -8

log "Hop 3 — vLLM engine log:"
# /metrics scrapes every few seconds drown out the POST line — filter them.
kubectl --context "$CLUSTER" logs -n "$NS" "$ENGINE_POD" -c engine --tail=300 \
  | grep -v 'GET /metrics' | grep -iE 'POST|completion|prompt' | tail -5 || \
  kubectl --context "$CLUSTER" logs -n "$NS" "$ENGINE_POD" -c engine --tail=5

log "Done. Proof bundle: response JSON above (note the model/usage fields),"
echo "    the matching access-log entry, EPP pick, engine log line, and the"
echo "    success counter increment."
