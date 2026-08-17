#!/usr/bin/env bash
# Sets up all student users and nodes on the central Jenkins. Jobs are
# shared, centrally-managed via JCasC (never here); read access is global.
# Usage: ./setup_students.sh [students.yaml] [creds_output.yaml]
set -euo pipefail

# Broken proxy env — see run_common.sh for why. Strip it.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

err() { echo -e "\033[1;33mERROR: $*\033[0m" >&2; }
hint() { echo -e "\033[1m$*\033[0m" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

parse_args() {
    CONFIG="${1:-${SCRIPT_DIR}/students.yaml}"
    CREDS_FILE="${2:-${SCRIPT_DIR}/students_credentials.yaml}"
    [[ -f "$CONFIG" ]] || { err "config not found: $CONFIG"; hint "Copy students.yaml.example to students.yaml and fill it in."; exit 1; }
    python3 -c "import yaml" 2>/dev/null || { err "pyyaml required — run: pip install pyyaml"; exit 1; }
}

# Parses the entire config in one shot. Tab-separated KEY/value lines,
# assigned via printf -v — no eval, no shell-quoting-injection surface
# regardless of what a student's name/password/etc. contains.
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
    print(f'STUDENT_{i}_PROJECT\t{s["project"]}')
    print(f'STUDENT_{i}_PASSWORD\t{s["password"]}')
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

create_student_user() {
    local name="$1" password="$2"
    echo "  → user '${name}'..."
    local crumb user_status response_file
    crumb=$(get_crumb)
    response_file=$(mktemp)
    user_status=$(curl -s -o "$response_file" -w "%{http_code}" \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "$crumb" \
        --data-urlencode "username=${name}" \
        --data-urlencode "password1=${password}" \
        --data-urlencode "password2=${password}" \
        --data-urlencode "fullname=${name}" \
        --data-urlencode "email=${name}@student.local" \
        "${JENKINS_URL}/securityRealm/createAccountByAdmin")
    # A non-302 response isn't necessarily "already exists" — Jenkins
    # re-renders the form (HTTP 200) with that message when it is;
    # anything else is a real failure.
    if [[ "$user_status" == "302" ]]; then
        echo "    ✓ created"
    elif grep -q "already taken" "$response_file"; then
        echo "    ⚠ already exists, skipped"
    else
        err "failed to create user '${name}' — HTTP ${user_status}"
        rm -f "$response_file"
        exit 1
    fi
    rm -f "$response_file"
}

create_agent_node() {
    local name="$1" node_name="$2"
    echo "  → node '${node_name}'..."
    local crumb node_json
    crumb=$(get_crumb)
    # Label must be sanitize_label(name), no "-vm" suffix — matches what
    # agentLabel() (Jenkinsfile) looks up at trigger time. One of four
    # intentional copies of this sed transform (see deploy_verify.sh).
    node_json='{
        "name": "'"${node_name}"'",
        "nodeDescription": "Student VM — '"${name}"'",
        "numExecutors": 1,
        "remoteFS": "/var/lib/jenkins-agent",
        "labelString": "'"$(echo -n "$name" | sed -E 's/[^A-Za-z0-9]+/-/g')"'",
        "mode": "EXCLUSIVE",
        "retentionStrategy": {"stapler-class": "hudson.slaves.RetentionStrategy$Always"},
        "nodeProperties": {"stapler-class-bag": "true"},
        "launcher": {
            "stapler-class": "hudson.slaves.JNLPLauncher",
            "workDirSettings": {
                "disabled": false,
                "internalDir": "remoting",
                "failIfWorkDirIsMissing": false
            }
        }
    }'
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "$crumb" \
        --data-urlencode "json=${node_json}" \
        "${JENKINS_URL}/computer/doCreateItem?name=${node_name}&type=hudson.slaves.DumbSlave" \
        && echo "    ✓ created" || echo "    ⚠ already exists, skipped"
}

# Sets AGENT_SECRET.
fetch_agent_secret() {
    local node_name="$1"
    AGENT_SECRET=$(curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        "${JENKINS_URL}/computer/${node_name}/jenkins-agent.jnlp" \
        | grep -oP '(?<=<argument>)[a-f0-9]{64}(?=</argument>)') \
        || { err "could not fetch secret for ${node_name}"; exit 1; }
}

# Full per-student provisioning: user + node. Read access on every job is
# already global (see jenkins.yaml.j2's authorizationStrategy) — nothing
# per-student to grant. Appends a result entry to the global RESULTS array.
provision_student() {
    local name="$1" project="$2" password="$3"
    local node_name="${name}-vm"

    echo ""
    echo "── ${name} (${project}) ──────────────────────────────────"

    create_student_user "$name" "$password"
    create_agent_node "$name" "$node_name"
    fetch_agent_secret "$node_name"

    RESULTS+=("${name}|${node_name}|${project}|${AGENT_SECRET}|${password}")
}

provision_all_students() {
    RESULTS=()
    local i name project password
    for i in $(seq 0 $((STUDENT_COUNT - 1))); do
        # Indirect expansion (${!var}), not eval.
        name="STUDENT_${i}_NAME"; name="${!name}"
        project="STUDENT_${i}_PROJECT"; project="${!project}"
        password="STUDENT_${i}_PASSWORD"; password="${!password}"
        provision_student "$name" "$project" "$password"
    done
}

print_credentials() {
    echo ""
    echo "============================================================"
    echo " Done. Send each student their credentials:"
    echo "============================================================"
    local entry name node project secret password
    for entry in "${RESULTS[@]}"; do
        IFS='|' read -r name node project secret password <<< "$entry"
        echo ""
        echo "  Student  : ${name}  (${project})"
        echo "  Jenkins  : ${JENKINS_URL}  user: ${name}  password: ${password}"
        echo "  central_url:          ${JENKINS_URL}"
        echo "  central_agent_name:   ${node}"
        echo "  central_agent_secret: ${secret}"
    done
    echo ""
    echo "============================================================"
}

# Fresh file every run — overwrites whatever was there before, not appended.
write_creds_file() {
    printf '%s\n' "${RESULTS[@]}" | JENKINS_URL="$JENKINS_URL" CREDS_FILE="$CREDS_FILE" python3 -c "
import sys, os, yaml

jenkins_url = os.environ['JENKINS_URL']
data = {}
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        continue
    name, node, project, secret, password = line.split('|')
    data[name] = {
        'project': project,
        'central_url': jenkins_url,
        'password': password,
        'agent_name': node,
        'agent_secret': secret,
    }
with open(os.environ['CREDS_FILE'], 'w') as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
"
    echo " Credentials written to: ${CREDS_FILE}"
    echo "============================================================"
}

main() {
    parse_args "$@"
    load_config

    COOKIE_JAR=$(mktemp)
    trap 'rm -f "$COOKIE_JAR"' EXIT

    provision_all_students
    print_credentials
    write_creds_file
}

main "$@"
