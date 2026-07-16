#!/usr/bin/env bash
# Brings up jenkins-node and provisions it with Jenkins.
# Usage: ./deploy_jenkins_node.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── vault.yml ────────────────────────────────────────────────────────────────
if [[ ! -f vault.yml ]]; then
    cp vault.yml.example vault.yml
    echo ""
    echo "vault.yml created from vault.yml.example."
    echo "Fill in all values then re-run: ./deploy_jenkins_node.sh"
    echo ""
    exit 0
fi

# If not yet encrypted, check for unfilled fields
if ! head -1 vault.yml | grep -q '\$ANSIBLE_VAULT'; then
    EMPTY=$(grep -nP ':\s*""' vault.yml || true)
    if [[ -n "$EMPTY" ]]; then
        echo "vault.yml has unfilled fields — please set them before continuing:"
        echo ""
        echo "$EMPTY"
        echo ""
        exit 1
    fi
fi

# ── sshd on host (VM needs to SSH back in to run CI) ─────────────────────────
if ! systemctl is-active --quiet sshd; then
    echo "→ Starting sshd on host (required for VM→host SSH)..."
    sudo systemctl enable --now sshd
fi

# ── Central Jenkins reachability ─────────────────────────────────────────────
CENTRAL_URL=$(grep 'vault_central_url' vault.yml 2>/dev/null | grep -v '^\s*#' | head -1 | awk -F'"' '{print $2}' || true)
if [[ -n "$CENTRAL_URL" ]]; then
    CENTRAL_HOST=$(python3 -c "from urllib.parse import urlparse; print(urlparse('${CENTRAL_URL}').hostname)" 2>/dev/null || true)
    CENTRAL_PORT=$(python3 -c "from urllib.parse import urlparse; p=urlparse('${CENTRAL_URL}'); print(p.port or (443 if p.scheme=='https' else 80))" 2>/dev/null || true)
    if [[ -n "$CENTRAL_HOST" ]]; then
        if ! curl -sf --connect-timeout 5 "${CENTRAL_URL}" -o /dev/null 2>/dev/null; then
            echo ""
            echo "ERROR: Cannot reach central Jenkins at ${CENTRAL_URL}"
            echo "       Ensure the URL is correct and the host machine can reach it."
            echo ""
            exit 1
        fi
        echo "→ Central Jenkins reachable at ${CENTRAL_URL}"
    fi
fi

# ── VM ───────────────────────────────────────────────────────────────────────
STATUS=$(vagrant status jenkins-node 2>/dev/null | awk '/jenkins-node/ {print $2}')
if [[ "$STATUS" != "running" ]]; then
    echo "→ jenkins-node is not running — starting..."
    vagrant up jenkins-node --no-provision
else
    echo "→ jenkins-node already running"
fi

# ── Vault password ───────────────────────────────────────────────────────────
read -rsp "Ansible Vault password: " VAULT_PASS
echo ""
VAULT_PASS_FILE=$(mktemp)
printf '%s' "$VAULT_PASS" > "$VAULT_PASS_FILE"
trap 'rm -f "$VAULT_PASS_FILE" /tmp/jenkins-node-ssh.cfg' EXIT

# ── Ansible ──────────────────────────────────────────────────────────────────
echo "→ Fetching SSH config..."
vagrant ssh-config jenkins-node > /tmp/jenkins-node-ssh.cfg

echo "→ Running deploy_jenkins.yaml..."
ANSIBLE_HOST_KEY_CHECKING=False \
  ansible-playbook \
    -i "jenkins-node," \
    --ssh-extra-args="-F /tmp/jenkins-node-ssh.cfg" \
    --vault-password-file="$VAULT_PASS_FILE" \
    -u vagrant \
    -b \
    deploy_jenkins.yaml

# ── Agent status (deploy_jenkins.yaml already starts/enables the service) ─────
AGENT_STATUS=$(vagrant ssh jenkins-node -c "systemctl is-active jenkins-agent" 2>/dev/null | tr -d '\r' || echo "unknown")

# ── Done ─────────────────────────────────────────────────────────────────────
VM_IP=$(vagrant ssh jenkins-node -c "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '\r')
echo ""
echo "============================================================"
echo " Jenkins node is up"
echo ""
echo " UI (forwarded):  http://localhost:8080"
echo " UI (direct):     http://${VM_IP}:8080"
echo " Agent service:   ${AGENT_STATUS}"
echo ""
if [[ "$AGENT_STATUS" != "active" ]]; then
    echo " Agent not connected yet."
    echo " Fill vault_central_agent_secret in vault.yml, then rerun:"
    echo "   ./deploy_jenkins_node.sh"
fi
echo "============================================================"
