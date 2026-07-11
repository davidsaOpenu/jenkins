#!/usr/bin/env bash
# Tears down the jenkins-node VM that deploy_jenkins_node.sh / local_test.sh
# bring up.
#
# Usage: ./cleanup.sh   (run from anywhere — cd's to its own directory first)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="jenkins-node"
# vagrant-libvirt names the domain "<cwd-basename>_<machine-name>" and (per
# this Vagrantfile's qemu_use_session = false) always under qemu:///system —
# bare virsh defaults to qemu:///session, a different scope where an
# unrelated stale domain of the same short name can exist and silently
# absorb this. Exact name, exact scope — never a pattern, never ambient.
LIBVIRT_URI="qemu:///system"
DOMAIN_NAME="$(basename "$SCRIPT_DIR")_${VM_NAME}"

# Vagrant's local .vagrant/ state (which holds the domain's ID) lives
# relative to cwd — cd there or vagrant destroy silently finds nothing to do.
cd "$SCRIPT_DIR"

echo "→ Tearing down ${VM_NAME}..."
vagrant destroy "$VM_NAME" -f

# Belt-and-braces: if the exact domain vagrant-libvirt would have named this
# VM still exists (e.g. created under a workspace that's since been wiped,
# so Vagrant's own local state never knew about it), remove it directly —
# by exact name only, so this can never touch another VM on this host.
if virsh -c "$LIBVIRT_URI" dominfo "$DOMAIN_NAME" &>/dev/null; then
    echo "→ Removing stale libvirt domain '${DOMAIN_NAME}'..."
    virsh -c "$LIBVIRT_URI" destroy "$DOMAIN_NAME" 2>/dev/null || true
    virsh -c "$LIBVIRT_URI" undefine "$DOMAIN_NAME" --remove-all-storage 2>/dev/null || true
fi
