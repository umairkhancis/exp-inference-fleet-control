#!/usr/bin/env bash
#
# test-failover.sh — proves both tiers of ml-team/chat end to end:
#
#   Phase 1  fleet serves     the local CPU-deployed qwen answers
#   Phase 2  failover         engine pod killed -> same requests, Claude answers
#   Phase 3  recovery         engine back -> traffic returns to the fleet
#
# Every request prints "asked for -> served by" so you can SEE which tier
# answered. That visibility is the debugging view: the response's "model"
# field is rewritten per backend (ml-team/qwen-cpu-demo = fleet,
# claude-* = failover). A client that doesn't look at that field never
# notices the switch — same URL, same model name, same API — which is the
# transparency the service is built for.
#
# The client half only needs the gateway URL (run client/gateway-tunnel.sh
# first). The kill/restore half is test harness, not client view: it uses
# kubectl against the inference cluster to delete the engine pod.
#
# Usage:
#   ./client/test-failover.sh
#   GATEWAY_URL=http://localhost:8081 ./client/test-failover.sh

set -euo pipefail

URL="${GATEWAY_URL:-http://localhost:8080}"
MODEL="${MODEL:-ml-team/chat}"
ENGINE_CONTEXT="${ENGINE_CONTEXT:-inference-cluster-1}"
ENGINE_NAMESPACE="${ENGINE_NAMESPACE:-mp-ml-team-51733}"
ENGINE_SELECTOR="modelplane.ai/deployment=qwen-cpu-demo,modelplane.ai/engine=qwen"
FLEET_MODEL="ml-team/qwen-cpu-demo"

FAILOVER_TIMEOUT=120    # s to wait for Claude to take over after the kill
RECOVERY_TIMEOUT=420    # s to wait for the fleet to take traffic back

# ---------------------------------------------------------------- helpers --
# One chat call. Prints "served_by<TAB>answer" on HTTP 200, returns 1 otherwise.
ask() {
  local body
  body=$(curl -s -m 60 "$URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    --data @- <<EOF
{
  "model": "$MODEL",
  "messages": [{"role": "user", "content": "Which company created you? Four words max."}],
  "max_tokens": 30
}
EOF
  ) || return 1
  local served
  served=$(printf '%s' "$body" | grep -o '"model":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -n "$served" ] || return 1
  local answer
  answer=$(printf '%s' "$body" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
  printf '%s\t%s\n' "$served" "$answer"
}

# Poll until the serving model matches (or stops matching) a pattern.
#   wait_for_tier <grep-pattern> <timeout-s> <label>
wait_for_tier() {
  local pattern=$1 timeout=$2 label=$3 waited=0 line served
  while [ "$waited" -le "$timeout" ]; do
    if line=$(ask); then
      served=${line%%$'\t'*}
      printf '    [%3ss] asked for %s -> served by %s\n' "$waited" "$MODEL" "$served"
      if printf '%s' "$served" | grep -q "$pattern"; then
        LAST_ANSWER=${line#*$'\t'}
        return 0
      fi
    else
      printf '    [%3ss] asked for %s -> no answer (gateway retrying/5xx)\n' "$waited" "$MODEL"
    fi
    sleep 5; waited=$((waited + 5))
  done
  echo "    FAIL: $label did not happen within ${timeout}s"
  return 1
}

PASS=()
FAIL=()
phase() { echo; echo "== Phase $1: $2"; }
record() { if [ "$1" -eq 0 ]; then PASS+=("$2"); else FAIL+=("$2"); fi; }

# ------------------------------------------------- phase 1: fleet serves --
phase 1 "priority to the local CPU-deployed model (fleet tier)"
rc=0; wait_for_tier "^${FLEET_MODEL}$" 60 "fleet serving" || rc=$?
record $rc "fleet serves"
[ $rc -eq 0 ] && echo "    answer: ${LAST_ANSWER}"

# --------------------------------------------------- phase 2: failover ----
phase 2 "priority to Claude (engine pod killed, same requests keep working)"
echo "    killing engine pod ($ENGINE_SELECTOR) on $ENGINE_CONTEXT..."
kubectl --context "$ENGINE_CONTEXT" -n "$ENGINE_NAMESPACE" \
  delete pod -l "$ENGINE_SELECTOR" --wait=false >/dev/null
rc=0; wait_for_tier '^claude' "$FAILOVER_TIMEOUT" "failover to Claude" || rc=$?
record $rc "failover to Claude"
[ $rc -eq 0 ] && echo "    answer: ${LAST_ANSWER}"

# --------------------------------------------------- phase 3: recovery ----
phase 3 "fleet recovers and takes traffic back"
echo "    waiting for the engine pod to be Ready again..."
# Short wait attempts in a loop: right after the kill the replacement pod
# may not exist yet, and `kubectl wait` errors on an empty selector match.
waited=0
until kubectl --context "$ENGINE_CONTEXT" -n "$ENGINE_NAMESPACE" \
    wait pod -l "$ENGINE_SELECTOR" --for=condition=Ready \
    --timeout=15s >/dev/null 2>&1; do
  waited=$((waited + 15))
  [ "$waited" -ge "$RECOVERY_TIMEOUT" ] && break
done
rc=0; wait_for_tier "^${FLEET_MODEL}$" "$RECOVERY_TIMEOUT" "traffic back on fleet" || rc=$?
record $rc "traffic returns to fleet"
[ $rc -eq 0 ] && echo "    answer: ${LAST_ANSWER}"

# ----------------------------------------------------------- summary ------
echo
echo "== Summary"
for p in "${PASS[@]:-}"; do [ -n "$p" ] && echo "   PASS  $p"; done
for f in "${FAIL[@]:-}"; do [ -n "$f" ] && echo "   FAIL  $f"; done
[ ${#FAIL[@]} -eq 0 ]
