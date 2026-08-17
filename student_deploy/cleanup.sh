#!/usr/bin/env bash
# Tears down the node-a/node-b VMs that run.sh's test flow brings up.
#
# Usage: ./cleanup.sh   (run from anywhere — cd's to its own directory first)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# vagrant-libvirt names the domain "<cwd-basename>_<machine-name>" and (per
# this Vagrantfile's qemu_use_session = false) always under qemu:///system —
# bare virsh defaults to qemu:///session, a different scope where an
# unrelated stale domain of the same short name can exist and silently
# absorb this. Exact name, exact scope — never a pattern, never ambient.
LIBVIRT_URI="qemu:///system"

# Vagrant's local .vagrant/ state (which holds the domain's ID) lives
# relative to cwd — cd there or vagrant destroy silently finds nothing to do.
cd "$SCRIPT_DIR"

for VM_NAME in node-a node-b; do
    echo "→ Tearing down ${VM_NAME}..."
    # Tolerate failure here (e.g. a name collision with a domain this
    # checkout's local .vagrant/ state doesn't know about) — the virsh
    # fallback below is what actually guarantees cleanup in that case, and
    # it must still run.
    vagrant destroy "$VM_NAME" -f || true

    # Belt-and-braces: if the exact domain vagrant-libvirt would have named
    # this VM still exists (e.g. created under a workspace that's since been
    # wiped, so Vagrant's own local state never knew about it), remove it
    # directly — by exact name only, so this can never touch another VM on
    # this host.
    DOMAIN_NAME="$(basename "$SCRIPT_DIR")_${VM_NAME}"
    if virsh -c "$LIBVIRT_URI" dominfo "$DOMAIN_NAME" &>/dev/null; then
        echo "→ Removing stale libvirt domain '${DOMAIN_NAME}'..."
        virsh -c "$LIBVIRT_URI" destroy "$DOMAIN_NAME" 2>/dev/null || true
        virsh -c "$LIBVIRT_URI" undefine "$DOMAIN_NAME" --remove-all-storage 2>/dev/null || true
    fi
done
