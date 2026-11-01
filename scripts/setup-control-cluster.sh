#!/usr/bin/env bash
#
# setup-control-cluster.sh
#
# Sets up the control cluster for the inference fleet: a multipass VM running
# a single-node minikube (docker driver) Kubernetes cluster whose API server
# is reachable from the host machine via a "modelplane" kubectl context.
#
# What it does (idempotent — safe to re-run):
#   1. Launches a multipass VM (default: modelplane, 6 CPUs / 10G RAM / 40G disk).
#   2. Installs Docker, minikube, and kubectl inside the VM.
#   3. Starts minikube with the API server exposed on the VM's IP and a TLS
#      cert valid for that IP (--apiserver-ips + --listen-address=0.0.0.0).
#   4. Makes the cluster survive VM reboots: docker restart policy
#      unless-stopped + a systemd unit that runs `minikube start` at boot.
#   5. Merges a kubeconfig context (named after the VM) into ~/.kube/config
#      on the host, with a timestamped backup of the original.
#   6. Verifies `kubectl get nodes` works from the host.
#
# Sizing note: the defaults (10G VM / 8G cluster / 6 CPUs) are what the full
# Modelplane v0.6 stack (Crossplane + 14 providers + 21 functions) needs to
# run without the apiserver being OOM-thrashed. A bare cluster can run far
# smaller, but undersizing leads to probe-kill crash loops once Modelplane
# is installed.
#
# Requirements on the host: multipass, kubectl.
#
# Usage:
#   ./setup-control-cluster.sh
#   VM_NAME=mycontrol VM_MEMORY=8G ./setup-control-cluster.sh

set -euo pipefail

# ---------------------------------------------------------------- config ----
VM_NAME="${VM_NAME:-modelplane}"
VM_IMAGE="${VM_IMAGE:-24.04}"
VM_CPUS="${VM_CPUS:-6}"
VM_MEMORY="${VM_MEMORY:-10G}"
VM_DISK="${VM_DISK:-40G}"
CLUSTER_MEMORY_MB="${CLUSTER_MEMORY_MB:-8192}" # memory cap of the minikube container
CLUSTER_CPUS="${CLUSTER_CPUS:-4}"              # kubelet CPU reservation
CONTEXT_NAME="${CONTEXT_NAME:-$VM_NAME}"       # kubectl context name on the host

log() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------- host prerequisites ----
for cmd in multipass kubectl; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is required on the host." >&2; exit 1; }
done

# ----------------------------------------------------------- 1. launch VM ---
if multipass info "$VM_NAME" >/dev/null 2>&1; then
  log "VM '$VM_NAME' already exists — skipping launch"
  multipass start "$VM_NAME" 2>/dev/null || true
else
  log "Launching VM '$VM_NAME' ($VM_CPUS CPUs, $VM_MEMORY RAM, $VM_DISK disk)"
  if ! multipass launch "$VM_IMAGE" --name "$VM_NAME" --cpus "$VM_CPUS" \
         --memory "$VM_MEMORY" --disk "$VM_DISK"; then
    # A corrupt cached image or stale manifest causes "Hash ... does not match".
    # Refreshing the manifest and retrying once fixes it.
    log "Launch failed — refreshing image manifest and retrying once"
    multipass find --force-update >/dev/null
    multipass launch "$VM_IMAGE" --name "$VM_NAME" --cpus "$VM_CPUS" \
      --memory "$VM_MEMORY" --disk "$VM_DISK"
  fi
fi

VM_IP=$(multipass info "$VM_NAME" | awk '/IPv4/ {print $2; exit}')
[ -n "$VM_IP" ] || { echo "ERROR: could not determine VM IP." >&2; exit 1; }
log "VM IP: $VM_IP"

# ------------------------------------------- 2. install tools inside VM -----
log "Installing Docker, minikube, kubectl inside the VM (skips what exists)"
multipass exec "$VM_NAME" -- bash -s <<'REMOTE'
set -euo pipefail
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh >/dev/null
  sudo usermod -aG docker "$USER"
fi
ARCH=$(uname -m); case "$ARCH" in aarch64) ARCH=arm64 ;; x86_64) ARCH=amd64 ;; esac
if ! command -v minikube >/dev/null; then
  curl -fsSLo /tmp/minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}"
  sudo install /tmp/minikube /usr/local/bin/minikube
fi
if ! command -v kubectl >/dev/null; then
  KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl"
  sudo install /tmp/kubectl /usr/local/bin/kubectl
fi
echo "docker:   $(docker --version)"
echo "minikube: $(minikube version --short 2>/dev/null || minikube version | head -1)"
REMOTE

# --------------------------------------------------- 3. start the cluster ---
# --listen-address=0.0.0.0 publishes the API server port on the VM's
# interfaces (the VM is only reachable from the host on the multipass NAT
# network, so this is not exposed beyond the host machine).
# --apiserver-ips puts the VM IP in the TLS cert SANs so the host can connect.
# --embed-certs makes the kubeconfig self-contained for copying to the host.
log "Starting minikube (${CLUSTER_CPUS} CPUs, ${CLUSTER_MEMORY_MB}MB)"
multipass exec "$VM_NAME" -- sg docker -c "minikube start \
  --driver=docker \
  --cpus=${CLUSTER_CPUS} \
  --memory=${CLUSTER_MEMORY_MB} \
  --apiserver-ips=${VM_IP} \
  --listen-address=0.0.0.0 \
  --embed-certs"

# ------------------------------------------------ 4. survive VM reboots -----
log "Enabling reboot persistence"
multipass exec "$VM_NAME" -- sg docker -c \
  "docker update --restart=unless-stopped minikube >/dev/null"
multipass exec "$VM_NAME" -- sudo bash -s <<'REMOTE'
set -euo pipefail
cat > /etc/systemd/system/minikube.service <<'UNIT'
[Unit]
Description=minikube
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=ubuntu
ExecStart=/usr/local/bin/minikube start

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable minikube.service >/dev/null 2>&1
REMOTE

# ----------------------------------------------- 5. host kubeconfig setup ---
# The docker driver publishes the API server's 8443 on a mapped port; find it.
API_PORT=$(multipass exec "$VM_NAME" -- sg docker -c "docker port minikube 8443" \
  | head -1 | awk -F: '{print $NF}' | tr -d '[:space:]')
[ -n "$API_PORT" ] || { echo "ERROR: could not determine API server port." >&2; exit 1; }
log "API server reachable at https://${VM_IP}:${API_PORT}"

TMP_KUBECONFIG=$(mktemp)
trap 'rm -f "$TMP_KUBECONFIG"' EXIT
multipass exec "$VM_NAME" -- cat /home/ubuntu/.kube/config > "$TMP_KUBECONFIG"
# Point at the VM, and rename cluster/context/user so nothing clashes with
# other clusters in the host kubeconfig.
sed -E -i '' \
  -e "s|server: https://.*|server: https://${VM_IP}:${API_PORT}|" \
  -e "s|name: minikube$|name: ${CONTEXT_NAME}|" \
  -e "s|cluster: minikube$|cluster: ${CONTEXT_NAME}|" \
  -e "s|user: minikube$|user: ${CONTEXT_NAME}|" \
  -e "s|current-context: minikube$|current-context: ${CONTEXT_NAME}|" \
  "$TMP_KUBECONFIG"

mkdir -p "$HOME/.kube"
if [ -f "$HOME/.kube/config" ]; then
  BACKUP="$HOME/.kube/config.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$HOME/.kube/config" "$BACKUP"
  log "Backed up existing kubeconfig to $BACKUP"
  # Remove any stale entries with the same names: in a KUBECONFIG merge the
  # first file wins, so leftovers from a previous cluster would otherwise
  # shadow the fresh credentials.
  kubectl config delete-context "$CONTEXT_NAME" >/dev/null 2>&1 || true
  kubectl config delete-cluster "$CONTEXT_NAME" >/dev/null 2>&1 || true
  kubectl config delete-user "$CONTEXT_NAME" >/dev/null 2>&1 || true
  MERGED=$(mktemp)
  KUBECONFIG="$HOME/.kube/config:$TMP_KUBECONFIG" kubectl config view --flatten > "$MERGED"
  command mv -f "$MERGED" "$HOME/.kube/config"
else
  command cp "$TMP_KUBECONFIG" "$HOME/.kube/config"
fi
chmod 600 "$HOME/.kube/config"

# ------------------------------------------------------------- 6. verify ----
log "Verifying cluster access from the host"
for i in 1 2 3 4 5; do
  if kubectl --context "$CONTEXT_NAME" get nodes; then
    log "Done. Use it with: kubectl --context ${CONTEXT_NAME} ..."
    exit 0
  fi
  echo "  not ready yet, retrying ($i/5)..."
  sleep 10
done
echo "ERROR: cluster did not become reachable from the host." >&2
exit 1
