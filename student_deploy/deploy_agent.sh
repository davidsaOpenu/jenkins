#!/usr/bin/env bash
# Installs a Jenkins agent — nothing else — on whatever machine this runs on.
# No Jenkins controller, no local JCasC, no plugin installation: just
# agent.jar plus a systemd service pointed at central Jenkins.
#
# Usage: sudo ./deploy_agent.sh <path-to-secrets.yml>
#
# Fill in secrets.yml.example (copy to secrets.yml first) with the
# central_url/central_agent_name/central_agent_secret the instructor gives
# you after running central_deploy/setup_students.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

if [[ $# -ne 1 ]]; then
    echo "Usage: sudo ./deploy_agent.sh <path-to-secrets.yml>" >&2
    exit 1
fi
SECRETS_FILE="$1"

if [[ "$EUID" -ne 0 ]]; then
    echo "✗ Must run as root (installs packages, systemd units): sudo $0 $*" >&2
    exit 1
fi

# A student's own machine can't be assumed to have anything beyond a base
# OS — install what's missing rather than failing. ansible isn't in CentOS
# Stream's base/AppStream repos — needs EPEL first.
if ! command -v ansible-playbook >/dev/null 2>&1; then
    dnf list installed epel-release >/dev/null 2>&1 || { echo "→ Installing EPEL (required for the ansible package)..."; dnf install -y epel-release; }
    echo "→ Installing missing prerequisite: ansible..."
    dnf install -y ansible
fi
[[ -f "$SECRETS_FILE" ]] || { echo "✗ Not found: $SECRETS_FILE" >&2; exit 1; }

ansible-playbook -i "localhost," -c local -b \
    -e "@${SECRETS_FILE}" \
    "${SCRIPT_DIR}/deploy_jenkins.yaml"

echo "→ Verifying agent service..."
if systemctl is-active --quiet jenkins-agent; then
    echo "✓ jenkins-agent is active"
else
    echo "✗ jenkins-agent is not active — check: systemctl status jenkins-agent" >&2
    exit 1
fi

echo ""
echo "============================================================"
echo " Agent installed."
central_url=$(python3 -c "import yaml; print(yaml.safe_load(open('${SECRETS_FILE}'))['central_url'])")
agent_name=$(python3 -c "import yaml; print(yaml.safe_load(open('${SECRETS_FILE}'))['central_agent_name'])")
echo " Central:  ${central_url}"
echo " Agent:    ${agent_name}"
echo "============================================================"
