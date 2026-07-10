#!/usr/bin/env bash
# Tears down the jenkins-01 VM that run.sh builds and leaves running.
#
# Invoked two ways:
#   - Automatically, by jobs/jenkins/Jenkinsfile's post.always block
#     (dir('swiftacular') { sh './cleanup.sh' }) — runs from a sibling
#     "swiftacular" checkout dir, one level up from this file's real home.
#   - Manually, run directly from repo root (e.g. after a real recovery run
#     of run.sh, once you're done with the VM it left running).
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
VAGRANT_VAGRANTFILE="$VAGRANTFILE" vagrant destroy "$VM_NAME" -f

# Belt-and-braces: if the exact domain vagrant-libvirt would have named this
# VM still exists (e.g. it was created under a workspace that's since been
# wiped, so Vagrant's own local state never knew about it), remove it
# directly — by exact name only, so this can never touch another VM sharing
# this libvirt host.
DOMAIN_NAME="$(basename "$REPO_ROOT")_${VM_NAME}"
if virsh -c "$LIBVIRT_URI" dominfo "$DOMAIN_NAME" &>/dev/null; then
    echo "→ Removing stale libvirt domain '${DOMAIN_NAME}'..."
    virsh -c "$LIBVIRT_URI" destroy "$DOMAIN_NAME" 2>/dev/null || true
    virsh -c "$LIBVIRT_URI" undefine "$DOMAIN_NAME" --remove-all-storage 2>/dev/null || true
fi
