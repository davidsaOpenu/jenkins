#!/usr/bin/env bash
# Tears down the jenkins-01 VM that run.sh builds and leaves running.
# Invoked automatically by jobs/jenkins/Jenkinsfile's post.always (via
# run_common.sh's copy over the scripts/cleanup.sh stub), or manually.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/central_deploy/Vagrantfile.jenkins" ]]; then
    REPO_ROOT="$SCRIPT_DIR"
elif [[ -f "${SCRIPT_DIR}/../jenkins/central_deploy/Vagrantfile.jenkins" ]]; then
    REPO_ROOT="${SCRIPT_DIR}/../jenkins"
else
    # This script exists specifically to guarantee the VM gets torn down —
    # failing loudly here beats silently reporting success while doing nothing.
    echo "✗ Could not locate central_deploy/Vagrantfile.jenkins — cannot tear down"
    exit 1
fi

VAGRANTFILE="${REPO_ROOT}/central_deploy/Vagrantfile.jenkins"
VM_NAME="jenkins-01"
# vagrant-libvirt connects here (Vagrantfile.jenkins sets qemu_use_session =
# false) — bare `virsh` defaults to qemu:///session instead, a completely
# separate per-user scope that never sees this domain.
LIBVIRT_URI="qemu:///system"

# Vagrant's local .vagrant/ state (which holds the domain's ID) lives relative
# to cwd, not next to VAGRANTFILE — cd there or vagrant destroy silently finds
# nothing to do, leaving the real libvirt domain orphaned.
cd "$REPO_ROOT"

echo "→ Tearing down ${VM_NAME}..."
# Tolerate failure here (e.g. a name collision with a domain this checkout's
# local .vagrant/ state doesn't know about) — the virsh fallback below is
# what actually guarantees cleanup in that case, and it must still run.
VAGRANT_VAGRANTFILE="$VAGRANTFILE" vagrant destroy "$VM_NAME" -f || true

# Belt-and-braces: if the exact domain vagrant-libvirt would have named
# still exists (e.g. Vagrant's own local state was wiped), remove it
# directly by exact name only, so this never touches another VM.
DOMAIN_NAME="$(basename "$REPO_ROOT")_${VM_NAME}"
if virsh -c "$LIBVIRT_URI" dominfo "$DOMAIN_NAME" &>/dev/null; then
    echo "→ Removing stale libvirt domain '${DOMAIN_NAME}'..."
    virsh -c "$LIBVIRT_URI" destroy "$DOMAIN_NAME" 2>/dev/null || true
    virsh -c "$LIBVIRT_URI" undefine "$DOMAIN_NAME" --remove-all-storage 2>/dev/null || true
fi
