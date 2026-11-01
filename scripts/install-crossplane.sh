#!/usr/bin/env bash
#
# install-crossplane.sh
#
# Installs Crossplane and the Modelplane Configuration onto the control
# cluster, following https://docs.modelplane.ai/install/:
#   1. helm install Crossplane (v2.3+) into crossplane-system with the flags
#      Modelplane requires.
#   2. Apply the Modelplane prerequisites manifest (namespace, RBAC, provider
#      runtime configs).
#   3. Apply the Modelplane Configuration package.
#   4. Wait for the Configuration to become Healthy (the documented check),
#      then best-effort wait for every dependency provider/function.
#
# Idempotent: helm upgrade --install and kubectl apply are safe to re-run.
#
# Requirements on the host: helm, kubectl, and a kubeconfig context for the
# control cluster (created by setup-control-cluster.sh).
#
# Usage:
#   ./install-crossplane.sh
#   CONTEXT_NAME=mycontrol MODELPLANE_VERSION=v0.6.0 ./install-crossplane.sh
#
# Note: the full dependency tree is ~14 providers and ~21 composition
# functions (~35 pods). On a control cluster smaller than ~8GB the largest
# cloud providers (aws-ec2, azure-network, gcp-compute) may flap between
# healthy and unhealthy; the Configuration itself still works.

set -euo pipefail

# ---------------------------------------------------------------- config ----
CONTEXT_NAME="${CONTEXT_NAME:-modelplane}"
CROSSPLANE_NAMESPACE="${CROSSPLANE_NAMESPACE:-crossplane-system}"
MODELPLANE_VERSION="${MODELPLANE_VERSION:-v0.6.0}"
PREREQS_URL="${PREREQS_URL:-https://docs.modelplane.ai/examples/install/prerequisites.yaml}"
CONFIG_WAIT="${CONFIG_WAIT:-15m}"          # wait for Configuration Healthy
PACKAGES_WAIT_SECS="${PACKAGES_WAIT_SECS:-900}" # best-effort wait for all packages

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
CONFIG_MANIFEST="$REPO_ROOT/manifests/modelplane-configuration.yaml"

log() { printf '\n==> %s\n' "$*"; }
kc() { kubectl --context "$CONTEXT_NAME" "$@"; }

# ---------------------------------------------------------- prerequisites ---
for cmd in helm kubectl; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is required on the host." >&2; exit 1; }
done
kc get nodes >/dev/null || { echo "ERROR: context '$CONTEXT_NAME' is not reachable." >&2; exit 1; }

# -------------------------------------------------- 1. install Crossplane ---
log "Installing Crossplane into $CROSSPLANE_NAMESPACE"
helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update >/dev/null
helm repo update crossplane-stable >/dev/null
helm upgrade --install crossplane crossplane-stable/crossplane \
  --kube-context "$CONTEXT_NAME" \
  --namespace "$CROSSPLANE_NAMESPACE" --create-namespace \
  --set "args={--enable-dependency-version-upgrades}" \
  --set-json 'provider.defaultActivations=[]' \
  --wait

# --------------------------------------- 2. Modelplane prerequisites --------
log "Applying Modelplane prerequisites"
kc apply -f "$PREREQS_URL"

# --------------------------------------- 3. Modelplane Configuration --------
if [ ! -f "$CONFIG_MANIFEST" ]; then
  log "Generating $CONFIG_MANIFEST"
  mkdir -p "$(dirname "$CONFIG_MANIFEST")"
  cat > "$CONFIG_MANIFEST" <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: modelplane
spec:
  package: xpkg.upbound.io/modelplane/modelplane:${MODELPLANE_VERSION}
EOF
fi
log "Applying Modelplane Configuration ($(basename "$CONFIG_MANIFEST"))"
kc apply -f "$CONFIG_MANIFEST"

# ------------------------------------------------------------- 4. verify ----
log "Waiting up to $CONFIG_WAIT for the Configuration to become Healthy"
kc wait configuration/modelplane --for=condition=Healthy --timeout="$CONFIG_WAIT"
log "Configuration is Healthy"

log "Waiting up to ${PACKAGES_WAIT_SECS}s for all dependency packages (best effort)"
deadline=$(( $(date +%s) + PACKAGES_WAIT_SECS ))
while :; do
  unhealthy=$(kc get providers,functions --no-headers 2>/dev/null | awk '$3!="True"' | wc -l | tr -d ' ')
  if [ "$unhealthy" = "0" ]; then
    log "All providers and functions are healthy"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "WARNING: $unhealthy package(s) not healthy yet (large cloud providers" >&2
    echo "WARNING: can flap on small clusters). Current state:" >&2
    kc get providers,functions --no-headers | awk '$3!="True" {print "  " $1}' >&2
    break
  fi
  sleep 20
done

log "Done. Installed packages:"
kc get configuration modelplane
kc get providers,functions --no-headers | awk '{print $2,$3}' | sort | uniq -c
