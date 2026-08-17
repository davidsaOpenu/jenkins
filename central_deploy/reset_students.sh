#!/usr/bin/env bash
# Tears down all student resources on the mock central Jenkins. Run
# setup_students.sh afterwards to redeploy. Usage: ./reset_students.sh
# [path/to/students.yaml] — safe to run multiple times.
set -euo pipefail

# Broken proxy env — see run_common.sh for why. Strip it.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

err() { echo -e "\033[1;33mERROR: $*\033[0m" >&2; }

CENTRAL_DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

parse_args() {
    CONFIG="${1:-${CENTRAL_DEPLOY_DIR}/students.yaml}"
    [[ -f "$CONFIG" ]] || { err "config not found: $CONFIG"; exit 1; }
    python3 -c "import yaml" 2>/dev/null || { err "pyyaml required — pip install pyyaml"; exit 1; }
}

# Tab-separated KEY/value lines, assigned via printf -v — no eval, no
# shell-quoting-injection surface regardless of what a student's name/etc.
# contains.
load_config() {
    local config_vars
    config_vars=$(python3 - "$CONFIG" <<'PYEOF'
import yaml, sys
d = yaml.safe_load(open(sys.argv[1]))
print(f'JENKINS_URL\t{d["central_url"]}')
print(f'JENKINS_USER\t{d["admin_user"]}')
print(f'JENKINS_PASS\t{d["admin_password"]}')
print(f'STUDENT_COUNT\t{len(d["students"])}')
for i, s in enumerate(d["students"]):
    print(f'STUDENT_{i}_NAME\t{s["name"]}')
PYEOF
    )
    while IFS=$'\t' read -r key value; do
        printf -v "$key" '%s' "$value"
    done <<< "$config_vars"
}

get_crumb() {
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])"
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

deprovision_all_students() {
    echo ""
    echo "── Tearing down all student resources ──────────────────────"
    local i name
    for i in $(seq 0 $((STUDENT_COUNT - 1))); do
        # Indirect expansion (${!var}), not eval.
        name="STUDENT_${i}_NAME"; name="${!name}"
        deprovision_student "$name"
    done
}

main() {
    parse_args "$@"
    load_config

    COOKIE_JAR=$(mktemp)
    trap 'rm -f "$COOKIE_JAR"' EXIT

    deprovision_all_students
}

main "$@"
