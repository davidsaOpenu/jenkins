#!/usr/bin/env bash
# Tears down student resources on the central Jenkins. Run
# setup_students.sh afterwards to redeploy. Usage: ./reset_students.sh
# (no arguments — reads central_deploy/gerrit_central.yml next to this
# script). Lists who's currently provisioned straight from Jenkins itself
# (not from a per-semester roster file, which may no longer exist) and
# prompts for which to delete.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "${REPO_ROOT}/deploy_verify.sh"

# Broken proxy env — see run_common.sh for why. Strip it.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

err() { echo -e "\033[1;33mERROR: $*\033[0m" >&2; }

detect_public_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$ip" ]]; then
        err "Could not auto-detect this machine's IP"
        exit 1
    fi
    echo "$ip"
}

# Connects using the durable admin config, not a per-semester student
# roster — gerrit_central.yml never gets regenerated/lost between
# semesters the way students.yaml does.
load_central_connection() {
    local accounts_file="${SCRIPT_DIR}/gerrit_central.yml"
    [[ -f "$accounts_file" ]] \
        || { err "config not found: $accounts_file"; echo "Copy gerrit_central.yml.example to gerrit_central.yml and fill it in." >&2; exit 1; }

    load_central_account "$accounts_file"

    local public_ip
    if [[ -n "$CENTRAL_JENKINS_PUBLIC_IP" ]]; then
        public_ip="$CENTRAL_JENKINS_PUBLIC_IP"
    else
        public_ip=$(detect_public_ip)
    fi
    local jenkins_port
    jenkins_port=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/roles/jenkins/defaults/main.yml'))['jenkins_http_port'])")

    JENKINS_URL="http://${public_ip}:${jenkins_port}"
    JENKINS_USER="$CENTRAL_GERRIT_USERNAME"
    JENKINS_PASS="$CENTRAL_JENKINS_ADMIN_PASSWORD"
}

get_crumb() {
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])"
}

# Every provisioned student has exactly one agent node, "<name>-vm" — ask
# Jenkins for those directly rather than trusting any file.
list_provisioned_students() {
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/computer/api/json?tree=computer[displayName]" \
        | python3 -c "
import sys, json
for c in json.load(sys.stdin)['computer']:
    if c['displayName'].endswith('-vm'):
        print(c['displayName'][:-len('-vm')])
"
}

delete_resource() {
    local url="$1" label="$2"
    local crumb http
    crumb=$(get_crumb)
    http=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "$crumb" -X POST "$url")
    [[ "$http" == "200" || "$http" == "302" ]] \
        && echo "  ✓ deleted ${label}" \
        || echo "  ⚠ ${label} not found (HTTP ${http}), skipping"
}

deprovision_student() {
    local name="$1"
    local node_name="${name}-vm"
    echo ""
    echo "  ${name}:"
    delete_resource "${JENKINS_URL}/computer/${node_name}/doDelete"     "node ${node_name}"
    delete_resource "${JENKINS_URL}/securityRealm/user/${name}/doDelete" "user ${name}"
}

main() {
    load_central_connection

    mapfile -t names < <(list_provisioned_students)
    if [[ ${#names[@]} -eq 0 ]]; then
        echo "No students currently provisioned."
        exit 0
    fi

    echo "Currently provisioned students:"
    printf '  %s\n' "${names[@]}"
    echo ""
    read -rp "Delete which? (names, space-separated, 'all', or blank to cancel): " answer
    [[ -z "$answer" ]] && { echo "Cancelled."; exit 0; }

    COOKIE_JAR=$(mktemp)
    trap 'rm -f "$COOKIE_JAR"' EXIT

    echo ""
    echo "── Tearing down selected student resources ──────────────────"
    if [[ "$answer" == "all" ]]; then
        for name in "${names[@]}"; do deprovision_student "$name"; done
    else
        for name in $answer; do deprovision_student "$name"; done
    fi
}

main "$@"
