#!/usr/bin/env bash
# Tears down the node-a/node-b VMs that run.sh's test flow brings up.
#
# Usage: ./cleanup.sh   (run from anywhere — cd's to its own directory first)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# vagrant-libvirt names the domain "<cwd-basename>_<machine-name>" always
# under qemu:///system — bare virsh defaults to qemu:///session, a
# different scope where a same-named stale domain could silently absorb this.
LIBVIRT_URI="qemu:///system"

# Vagrant's local .vagrant/ state (which holds the domain's ID) lives
# relative to cwd — cd there or vagrant destroy silently finds nothing to do.
cd "$SCRIPT_DIR"

for VM_NAME in node-a node-b; do
    echo "→ Tearing down ${VM_NAME}..."
    # Tolerate failure here (e.g. a stale-state mismatch) — the virsh
    # fallback below is what actually guarantees cleanup, and must still run.
    vagrant destroy "$VM_NAME" -f || true

    # Belt-and-braces: if the exact domain still exists (e.g. Vagrant's own
    # state was wiped), remove it directly by exact name only, so this
    # never touches another VM on this host.
    DOMAIN_NAME="$(basename "$SCRIPT_DIR")_${VM_NAME}"
    if virsh -c "$LIBVIRT_URI" dominfo "$DOMAIN_NAME" &>/dev/null; then
        echo "→ Removing stale libvirt domain '${DOMAIN_NAME}'..."
        virsh -c "$LIBVIRT_URI" destroy "$DOMAIN_NAME" 2>/dev/null || true
        virsh -c "$LIBVIRT_URI" undefine "$DOMAIN_NAME" --remove-all-storage 2>/dev/null || true
    fi
done
