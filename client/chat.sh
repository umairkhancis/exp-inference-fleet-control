#!/usr/bin/env bash
#
# chat.sh — the raw client view: nothing but curl against the platform's
# OpenAI-compatible API. One URL, one model name (ml-team/chat); no
# cluster, replica, or provider in sight. Prints the raw JSON response —
# pipe through `jq .` for pretty output, or `jq -r .model` to see who
# actually served it (ml-team/qwen-cpu-demo = fleet, claude-* = failover).
#
# Usage:
#   ./chat.sh "your prompt"
#   GATEWAY_URL=http://localhost:8081 MODEL=ml-team/qwen-cpu ./chat.sh "hi"
#
# Keep prompts free of double quotes/backslashes (naive JSON templating).

set -euo pipefail

URL="${GATEWAY_URL:-http://localhost:8080}"
MODEL="${MODEL:-ml-team/chat}"
PROMPT="${1:-Say hello in one short sentence.}"

curl -s -m 120 "$URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  --data @- <<EOF
{
  "model": "$MODEL",
  "messages": [{"role": "user", "content": "$PROMPT"}],
  "max_tokens": 120
}
EOF
echo
