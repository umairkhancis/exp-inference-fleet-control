#!/usr/bin/env bash
#
# fleet-stop.sh — park the whole PoC fleet without losing any state.
#
# `multipass stop` shuts the VMs down cleanly and keeps their disks, so
# clusters, pulled images, downloaded model weights, and all Modelplane
# registrations survive. Bring everything back with: scripts/fleet-start.sh

set -euo pipefail

VMS=(inference-cluster-1 modelplane)

for vm in "${VMS[@]}"; do
  state=$(multipass info "$vm" --format csv 2>/dev/null | tail -1 | cut -d, -f2 || echo missing)
  case "$state" in
    Stopped)  echo "==> $vm already stopped" ;;
    missing)  echo "==> $vm not found — skipping" ;;
    *)        echo "==> Stopping $vm"; multipass stop "$vm" ;;
  esac
done

echo
multipass list
echo
echo "Fleet parked. Restart with: ./scripts/fleet-start.sh"
