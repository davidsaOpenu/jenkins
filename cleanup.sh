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

echo "→ Tearing down ${VM_NAME}..."
VAGRANT_VAGRANTFILE="$VAGRANTFILE" vagrant destroy "$VM_NAME" -f
