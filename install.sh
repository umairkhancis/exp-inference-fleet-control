#!/usr/bin/env bash
# One command, full stack: a Modelplane control cluster (Crossplane + the
# Modelplane Configuration on minikube-in-multipass) + a registered BYO
# inference cluster + Qwen2.5-0.5B served by vLLM on CPU + one model name,
# ml-team/chat, with Claude as transparent failover.
#
#   curl -fsSL https://raw.githubusercontent.com/umairkhancis/exp-inference-fleet-control/main/install.sh | bash
#
# (or, from a clone: ./install.sh)
#
# Requirements: Apple Silicon Mac, 24GB RAM, ~40GB disk, Homebrew.
# Everything else (Multipass, kubectl, helm, jq) is installed for you.
# Optional: export ANTHROPIC_API_KEY=sk-ant-... beforehand to enable the
# Claude failover tier (skipped with a note otherwise; `make chat` adds it
# any time later).
# Safe to rerun after any failure — every layer is idempotent.

set -euo pipefail

# Everything lives in main() so that `curl | bash` parses the WHOLE script
# before running any of it — otherwise a child process reading stdin would
# swallow the not-yet-read remainder of the script and bash would stop early.
main() {

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[0;36m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; CYAN=""; RESET=""
fi

echo "${CYAN}${BOLD}"
cat <<'EOF'
  _____ _           _
 |  ___| | ___  ___| |_
 | |_  | |/ _ \/ _ \ __|
 |  _| | |  __/  __/ |_
 |_|   |_|\___|\___|\__|
   ____            _             _
  / ___|___  _ __ | |_ _ __ ___ | |
 | |   / _ \| '_ \| __| '__/ _ \| |
 | |__| (_) | | | | |_| | | (_) | |
  \____\___/|_| |_|\__|_|  \___/|_|
EOF
echo "${RESET}"
echo "  ${BOLD}Inference Unpacked${RESET} ${DIM}· fleet control · one model name, fleet first, Claude failover${RESET}"
echo

REPO_URL="https://github.com/umairkhancis/exp-inference-fleet-control.git"
REPO_BRANCH="main"
REPO_DIR="exp-inference-fleet-control"

# Bootstrap: when piped from curl there is no repo around this script — clone it.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "$(dirname "${BASH_SOURCE[0]}")/Makefile" ]]; then
  cd "$(dirname "${BASH_SOURCE[0]}")"
else
  [[ -d "${REPO_DIR}" ]] || git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
  cd "${REPO_DIR}"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  make up            # all layers, including the Claude failover tier
else
  echo "${BOLD}NOTE:${RESET} ANTHROPIC_API_KEY is not set — skipping the Claude failover"
  echo "tier (ml-team/chat). Export it and run 'make chat' any time to add it."
  echo
  make host-prereqs control-cluster modelplane inference-cluster-1 models verify
fi

ADDRESS="$(kubectl --context modelplane get ig public -o jsonpath='{.status.endpoints.openAI}' 2>/dev/null || true)"
echo
echo "=============================================================="
echo "  Done. Your fleet is live."
echo
echo "  Control plane:        kubectl --context modelplane get ic,ig,md,ms -A"
echo "  Gateway (in-VM):      ${ADDRESS:-kubectl --context modelplane get ig public}"
echo "  From the mac:         ./client/gateway-tunnel.sh   # -> http://localhost:8080"
echo
echo "  Try it (after the tunnel is up):"
echo "  ./client/chat.sh \"What is the capital of France?\""
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "    (use MODEL=ml-team/qwen-cpu — ml-team/chat needs 'make chat' first)"
fi
echo
echo "  Prove the failover:   make tunnel   # keep running, then in another shell:"
echo "                        make failover"
echo "  Park / resume:        make stop / make start"
echo "  Tear down:            make down"
echo "=============================================================="

}

main "$@"
