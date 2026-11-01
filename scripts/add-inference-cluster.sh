#!/usr/bin/env bash
#
# add-inference-cluster.sh
#
# Brings a BYO inference cluster from nothing to Ready and registered with
# the Modelplane control cluster, following manifests/<name>/README.md:
#
#   1. Creates the multipass VM + minikube cluster (reuses
#      setup-control-cluster.sh, which is idempotent).
#   2. BYO prerequisites: pool labels on the node, MetalLB + address pool.
#   3. Registers it: kubeconfig Secret on the control cluster, then applies
#      the InferenceClass / InferenceCluster / InferenceGateway manifests
#      and waits for each to become Ready.
#   4. Smoke-tests the gateway endpoint from inside the VM.
#
# Idempotent — safe to re-run; each step skips or re-applies cleanly.
#
# Requirements on the host: multipass, kubectl, a reachable control-cluster
# context (default "modelplane") with Modelplane installed, and a manifest
# folder manifests/<cluster-name>/ containing inference-class.yaml,
# inference-cluster.yaml, inference-gateway.yaml, metallb-config.yaml.
#
# Usage:
#   ./add-inference-cluster.sh [cluster-name]     # default: inference-cluster-1
#   CONTROL_CONTEXT=mycontrol ./add-inference-cluster.sh inference-cluster-2

set -euo pipefail

# ---------------------------------------------------------------- config ----
CLUSTER_NAME="${1:-${CLUSTER_NAME:-inference-cluster-1}}"
CONTROL_CONTEXT="${CONTROL_CONTEXT:-modelplane}"
POOL_NAME="${POOL_NAME:-cpu-pool}"
SECRET_NAME="${CLUSTER_NAME}-kubeconfig"
SECRET_NAMESPACE="${SECRET_NAMESPACE:-crossplane-system}"
# VM sizing for the CPU-only PoC cluster (see manifests/<name>/README.md).
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY="${VM_MEMORY:-6G}"
VM_DISK="${VM_DISK:-30G}"
CLUSTER_CPUS="${CLUSTER_CPUS:-3}"
CLUSTER_MEMORY_MB="${CLUSTER_MEMORY_MB:-4096}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MANIFEST_DIR="$REPO_ROOT/manifests/$CLUSTER_NAME"

log() { printf '\n==> %s\n' "$*"; }

# ------------------------------------------------------------- preflight ----
for cmd in multipass kubectl; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is required on the host." >&2; exit 1; }
done
[ -d "$MANIFEST_DIR" ] || { echo "ERROR: no manifest folder at $MANIFEST_DIR" >&2; exit 1; }
for f in inference-class.yaml inference-cluster.yaml inference-gateway.yaml metallb-config.yaml; do
  [ -f "$MANIFEST_DIR/$f" ] || { echo "ERROR: missing $MANIFEST_DIR/$f" >&2; exit 1; }
done
log "Checking control cluster context '$CONTROL_CONTEXT'"
kubectl --context "$CONTROL_CONTEXT" get ns "$SECRET_NAMESPACE" >/dev/null \
  || { echo "ERROR: control cluster not reachable or '$SECRET_NAMESPACE' missing (is Modelplane installed?)" >&2; exit 1; }

# ------------------------------------------------- 1. VM + minikube cluster -
log "Creating/starting cluster '$CLUSTER_NAME' (reusing setup-control-cluster.sh)"
VM_NAME="$CLUSTER_NAME" CONTEXT_NAME="$CLUSTER_NAME" \
VM_CPUS="$VM_CPUS" VM_MEMORY="$VM_MEMORY" VM_DISK="$VM_DISK" \
CLUSTER_CPUS="$CLUSTER_CPUS" CLUSTER_MEMORY_MB="$CLUSTER_MEMORY_MB" \
  "$SCRIPT_DIR/setup-control-cluster.sh"

# --------------------------------------------- 2a. pool labels on the node --
# Without these, Modelplane worker pods stay Pending and the pool publishes
# no cores.
log "Labeling nodes for pool '$POOL_NAME'"
kubectl --context "$CLUSTER_NAME" label nodes --all --overwrite \
  "modelplane.ai/pool=$POOL_NAME" "modelplane.ai/cpu=true"

# --------------------------------------------------------- 2b. MetalLB ------
# The gateway needs a LoadBalancer implementation to get an external address.
# --force skips minikube's interactive "3rd party addon" confirmation, which
# otherwise hangs forever when stdin is not a TTY; the kubectl check makes
# re-runs skip the enable entirely.
log "Enabling MetalLB addon and applying its address pool"
if kubectl --context "$CLUSTER_NAME" -n metallb-system get deploy controller >/dev/null 2>&1; then
  log "MetalLB already enabled — skipping"
else
  multipass exec "$CLUSTER_NAME" -- sg docker -c "minikube addons enable metallb --force" >/dev/null
fi
kubectl --context "$CLUSTER_NAME" apply -f "$MANIFEST_DIR/metallb-config.yaml"

# ------------------------------------------------ 3a. kubeconfig Secret -----
# The server address must be reachable from pods on the control cluster,
# i.e. the multipass VM IP (setup-control-cluster.sh already writes it into
# the host kubeconfig). create --dry-run | apply makes this idempotent.
log "Creating kubeconfig Secret '$SECRET_NAME' on the control cluster"
SERVER=$(kubectl config view --context "$CLUSTER_NAME" --minify -o jsonpath='{.clusters[0].cluster.server}')
case "$SERVER" in
  *127.0.0.1*|*localhost*) echo "ERROR: kubeconfig server is $SERVER — not reachable from control-cluster pods." >&2; exit 1 ;;
esac
kubectl config view --context "$CLUSTER_NAME" --minify --flatten \
  | kubectl --context "$CONTROL_CONTEXT" create secret generic "$SECRET_NAME" \
      -n "$SECRET_NAMESPACE" --from-file=kubeconfig=/dev/stdin \
      --dry-run=client -o yaml \
  | kubectl --context "$CONTROL_CONTEXT" apply -f -

# ------------------------------------- 3b. class + cluster registration -----
log "Applying InferenceClass and InferenceCluster"
kubectl --context "$CONTROL_CONTEXT" apply -f "$MANIFEST_DIR/inference-class.yaml"
kubectl --context "$CONTROL_CONTEXT" apply -f "$MANIFEST_DIR/inference-cluster.yaml"
log "Waiting for InferenceCluster to become Ready (up to 20m: installs the serving stack)"
kubectl --context "$CONTROL_CONTEXT" wait --for=condition=Ready \
  -f "$MANIFEST_DIR/inference-cluster.yaml" --timeout=20m

# ------------------------------------------------------- 3c. gateway --------
log "Applying InferenceGateway"
kubectl --context "$CONTROL_CONTEXT" apply -f "$MANIFEST_DIR/inference-gateway.yaml"
log "Waiting for InferenceGateway to become Ready (up to 5m)"
kubectl --context "$CONTROL_CONTEXT" wait --for=condition=Ready \
  -f "$MANIFEST_DIR/inference-gateway.yaml" --timeout=5m

ENDPOINTS=$(kubectl --context "$CONTROL_CONTEXT" get \
  -f "$MANIFEST_DIR/inference-gateway.yaml" -o jsonpath='{.status.endpoints}')
GATEWAY_IP=$(kubectl --context "$CONTROL_CONTEXT" get \
  -f "$MANIFEST_DIR/inference-gateway.yaml" -o jsonpath='{.status.address}')

# ------------------------------------------------------- 4. smoke test ------
# The MetalLB address only exists inside the VM's docker network, so test
# from inside the VM. Any HTTP status (even 404 with no models deployed)
# proves the LB + gateway path works.
log "Smoke-testing gateway at $GATEWAY_IP from inside the VM"
HTTP_CODE=$(multipass exec "$CLUSTER_NAME" -- \
  curl -s -m 10 -o /dev/null -w '%{http_code}' "http://$GATEWAY_IP/v1/models" || echo "000")
if [ "$HTTP_CODE" = "000" ]; then
  echo "WARNING: gateway did not answer HTTP from inside the VM." >&2
else
  log "Gateway answered (HTTP $HTTP_CODE)"
fi

log "Done. '$CLUSTER_NAME' is registered and Ready."
echo "    Endpoints (reachable from inside the VM; plain HTTP, no auth): $ENDPOINTS"
