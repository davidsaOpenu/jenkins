# Shared by setup_students.sh and reset_students.sh. Sourced only — how
# both log in to the central Jenkins as admin.

err() { echo -e "\033[1;33mERROR: $*\033[0m" >&2; }

# Sets JENKINS_URL / JENKINS_USER / JENKINS_PASS. Each comes from the
# environment (JENKINS_URL, JENKINS_ADMIN_USER, JENKINS_ADMIN_PASSWORD —
# how CI passes them), otherwise it is asked for on the terminal.
load_jenkins_connection() {
    JENKINS_URL="${JENKINS_URL:-}"
    JENKINS_USER="${JENKINS_ADMIN_USER:-}"
    JENKINS_PASS="${JENKINS_ADMIN_PASSWORD:-}"
    [[ -n "$JENKINS_URL" ]]  || read -rp "Jenkins URL (http://<central-host>:<port>): " JENKINS_URL || true
    [[ -n "$JENKINS_USER" ]] || read -rp "Admin user: " JENKINS_USER || true
    if [[ -z "$JENKINS_PASS" ]]; then
        read -rsp "Admin password: " JENKINS_PASS || true
        echo "" >&2
    fi
    JENKINS_URL="${JENKINS_URL%/}"
    [[ -n "$JENKINS_URL" && -n "$JENKINS_USER" && -n "$JENKINS_PASS" ]] \
        || { err "Jenkins URL, admin user and admin password are all required — type them when asked, or set JENKINS_URL, JENKINS_ADMIN_USER, JENKINS_ADMIN_PASSWORD"; exit 1; }
}

get_crumb() {
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])"
}
