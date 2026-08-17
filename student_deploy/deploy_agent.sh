#!/usr/bin/env bash
# Installs a Jenkins agent — just agent.jar + a systemd service pointed at
# central Jenkins. Usage: sudo ./deploy_agent.sh <path-to-secrets.yml> —
# fill in secrets.yml.example with the values the instructor gives you.
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

# A student's machine can't be assumed to have anything beyond a base OS,
# on any distro — install Ansible with whichever package manager it has.
install_ansible() {
    echo "→ Installing missing prerequisite: ansible..."
    if command -v dnf >/dev/null 2>&1; then
        # ansible isn't in CentOS Stream's base/AppStream repos — needs
        # EPEL first. Not needed on Fedora, already in its base repos.
        if [[ "$(. /etc/os-release && echo "$ID")" != "fedora" ]] \
            && ! dnf list installed epel-release >/dev/null 2>&1; then
            echo "→ Installing EPEL (required for the ansible package)..."
            dnf install -y epel-release
        fi
        dnf install -y ansible
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ansible
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install ansible
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm --needed ansible
    else
        echo "✗ No known package manager (dnf/apt/zypper/pacman) — install Ansible yourself, then re-run." >&2
        exit 1
    fi
}

command -v ansible-playbook >/dev/null 2>&1 || install_ansible
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
