#!/usr/bin/env bash
# Tears down all student resources on the mock central Jenkins.
# Run setup_students.sh afterwards to redeploy.
#
# Usage: ./reset_students.sh [path/to/students.yaml]
# Safe to run multiple times.
set -euo pipefail

# Same lesson as run.sh: the central host exports a broken proxy, and curl
# silently routes plain-http requests through it — every Jenkins API call
# here would hang for minutes and return empty. Strip the whole family.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

err() { echo -e "\033[1;33mERROR: $*\033[0m" >&2; }

CENTRAL_DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-${CENTRAL_DEPLOY_DIR}/students.yaml}"
[[ -f "$CONFIG" ]] || { err "config not found: $CONFIG"; exit 1; }
python3 -c "import yaml" 2>/dev/null || { err "pyyaml required — pip install pyyaml"; exit 1; }

eval "$(python3 - "$CONFIG" <<'PYEOF'
import yaml, sys
d = yaml.safe_load(open(sys.argv[1]))
print(f'JENKINS_URL="{d["central_url"]}"')
print(f'JENKINS_USER="{d["admin_user"]}"')
print(f'JENKINS_PASS="{d["admin_password"]}"')
print(f'STUDENT_COUNT={len(d["students"])}')
for i, s in enumerate(d["students"]):
    print(f'STUDENT_{i}_NAME="{s["name"]}"')
    print(f'STUDENT_{i}_PROJECT="{s["project"]}"')
PYEOF
)"

COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

get_crumb() {
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])"
}

delete_resource() {
    local url="$1" label="$2"
    CRUMB=$(get_crumb)
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "$CRUMB" -X POST "$url")
    [[ "$HTTP" == "200" || "$HTTP" == "302" ]] \
        && echo "  ✓ deleted ${label}" \
        || echo "  ⚠ ${label} not found (HTTP ${HTTP}), skipping"
}

echo ""
echo "── Tearing down all student resources ──────────────────────"
for i in $(seq 0 $((STUDENT_COUNT - 1))); do
    eval "NAME=\$STUDENT_${i}_NAME PROJECT=\$STUDENT_${i}_PROJECT"
    NODE_NAME="${NAME}-vm"
    JOB_NAME="${PROJECT}-${NODE_NAME}"
    echo ""
    echo "  ${NAME}:"
    delete_resource "${JENKINS_URL}/job/${JOB_NAME}/doDelete"          "job  ${JOB_NAME}"
    delete_resource "${JENKINS_URL}/computer/${NODE_NAME}/doDelete"     "node ${NODE_NAME}"
    delete_resource "${JENKINS_URL}/securityRealm/user/${NAME}/doDelete" "user ${NAME}"
done
