#!/usr/bin/env bash
# Sets up all student users and nodes on the central Jenkins. Usage:
# ./setup_students.sh [students.yaml] [creds_output.yaml] — asks for the
# Jenkins URL and admin login (see jenkins_connection.sh for the CI form).
set -euo pipefail

# Broken proxy env — see run_common.sh for why. Strip it.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

hint() { echo -e "\033[1m$*\033[0m" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/jenkins_connection.sh"

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

# Provisioning updates existing users — a student named like the admin
# would get the admin's password reset. Jenkins ids are case-insensitive.
refuse_admin_as_student() {
    local i name
    for i in $(seq 0 $((STUDENT_COUNT - 1))); do
        name="STUDENT_${i}_NAME"; name="${!name}"
        [[ "${name,,}" != "${JENKINS_USER,,}" ]] \
            || { err "student name '${name}' is the admin account — refusing to overwrite it"; exit 1; }
    done
}

# A student's name is also their node's routing label (agentLabel() in
# jobs/jenkins-dr-test/Jenkinsfile), so it must match no node but their
# own "<name>-vm". GerritHub usernames are GitHub logins — letters, digits,
# single inner hyphens — whose label is the name itself, so no two can
# collide. A name ending in "-vm" would be another student's node name
# (nodes carry their own name as a label), and built-in/master is the
# controller. Ids are compared lowercased: Jenkins user ids ignore case.
refuse_unsafe_names() {
    local i name seen=" "
    for i in $(seq 0 $((STUDENT_COUNT - 1))); do
        name="STUDENT_${i}_NAME"; name="${!name}"
        [[ "$name" =~ ^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]] \
            || { err "student name '${name}' is not a GerritHub username (letters, digits, single inner hyphens)"; exit 1; }
        [[ "${name,,}" != *-vm && "${name,,}" != built-in && "${name,,}" != master ]] \
            || { err "student name '${name}' would match another node's name — refusing"; exit 1; }
        [[ "$seen" != *" ${name,,} "* ]] \
            || { err "student name '${name}' is listed twice (names ignore case)"; exit 1; }
        seen+="${name,,} "
    done
}

# Emits the roster Jenkins needs as base64 JSON — nothing a student's
# name/password contains can break out into the Groovy below. Label is one
# of four intentional copies of sanitize_label (see deploy_verify.sh).
build_roster_b64() {
    python3 - "$CONFIG" <<'PYEOF'
import base64, json, re, sys, yaml

roster = [
    {
        "name": str(s["name"]),
        "password": str(s["password"]),
        "node": f'{s["name"]}-vm',
        "label": re.sub(r"[^A-Za-z0-9]+", "-", str(s["name"])),
    }
    for s in yaml.safe_load(open(sys.argv[1]))["students"]
]
print(base64.b64encode(json.dumps(roster).encode()).decode())
PYEOF
}

# Runs inside Jenkins via /scriptText. Creates or updates each student's
# user (password) and node (label/config), then prints the node's agent
# secret as "SECRET<TAB>name<TAB>secret".
provision_groovy() {
    cat <<'GROOVY'
import groovy.json.JsonSlurper
import hudson.model.Node
import hudson.model.User
import hudson.security.HudsonPrivateSecurityRealm
import hudson.slaves.DumbSlave
import hudson.slaves.JNLPLauncher
import hudson.slaves.RetentionStrategy
import jenkins.model.Jenkins

def roster = new JsonSlurper().parseText(new String('__ROSTER_B64__'.decodeBase64(), 'UTF-8'))
def jenkins = Jenkins.get()

// Before changing anything: each student's label must match no node but
// their own — not another node's name, nor a label some other node
// (the built-in one included) already carries. See refuse_unsafe_names.
roster.each { s ->
    def others = (jenkins.getLabelAtom(s.label)?.nodes ?: []).findAll { it.nodeName != s.node }
    if (jenkins.getNode(s.label) != null || others) {
        throw new IllegalStateException("label '${s.label}' of student '${s.name}' already matches another node — refusing")
    }
}

roster.each { s ->
    def user = User.getById(s.name, false)
    if (user == null) {
        jenkins.securityRealm.createAccount(s.name, s.password)
    } else {
        user.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword(s.password))
    }

    // addNode replaces a same-named node, so label/config always update.
    def node = new DumbSlave(s.node, '/var/lib/jenkins-agent', new JNLPLauncher())
    node.nodeDescription = "Student VM — ${s.name}"
    node.numExecutors = 1
    node.labelString = s.label
    node.mode = Node.Mode.EXCLUSIVE
    node.retentionStrategy = new RetentionStrategy.Always()
    jenkins.addNode(node)

    println "SECRET\t${s.name}\t${jenkins.getComputer(s.node).jnlpMac}"
}
GROOVY
}

# One /scriptText call for the whole roster; Jenkins' reply lands in $1.
run_provision_script() {
    local response_file="$1" script_file="${TMP_DIR}/provision.groovy"
    local groovy crumb http
    groovy=$(provision_groovy)
    # Sent from a file (script@...), not argv — keeps passwords out of `ps`.
    printf '%s\n' "${groovy/__ROSTER_B64__/$(build_roster_b64)}" > "$script_file"

    crumb=$(get_crumb 2>/dev/null) || { err "cannot log in to ${JENKINS_URL} as '${JENKINS_USER}' — check the URL, admin user and admin password"; exit 1; }
    http=$(curl -s -o "$response_file" -w "%{http_code}" \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "$crumb" \
        --data-urlencode "script@${script_file}" \
        "${JENKINS_URL}/scriptText")
    [[ "$http" == "200" ]] || { err "student provisioning failed — HTTP ${http} from ${JENKINS_URL}/scriptText"; exit 1; }
}

# Read access on every job and build log is already global, and approving
# a build needs no grant (see jenkins.yaml.j2's authorizationStrategy) —
# nothing per-student to grant. Fills the global RESULTS array.
provision_all_students() {
    RESULTS=()
    local response_file="${TMP_DIR}/provision.out"
    run_provision_script "$response_file"

    local -A secrets=()
    local tag name secret
    while IFS=$'\t' read -r tag name secret; do
        # "n:" prefix — bash rejects an empty array key (blank student name).
        [[ "$tag" == "SECRET" ]] && secrets["n:${name}"]="$secret"
    done < "$response_file"

    # Jenkins answers 200 even when the script throws — a student with no
    # valid secret line is the real failure signal.
    local i project password
    for i in $(seq 0 $((STUDENT_COUNT - 1))); do
        # Indirect expansion (${!var}), not eval.
        name="STUDENT_${i}_NAME"; name="${!name}"
        project="STUDENT_${i}_PROJECT"; project="${!project}"
        password="STUDENT_${i}_PASSWORD"; password="${!password}"
        secret="${secrets["n:${name}"]:-}"

        echo ""
        echo "── ${name} (${project}) ──────────────────────────────────"
        if [[ ! "$secret" =~ ^[a-f0-9]{64}$ ]]; then
            err "provisioning '${name}' failed — Jenkins replied:"
            cat "$response_file" >&2
            exit 1
        fi
        echo "  ✓ user '${name}' and node '${name}-vm' created or updated"
        RESULTS+=("${name}|${name}-vm|${project}|${secret}|${password}")
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
# Holds passwords and agent secrets — owner-only, even if it already existed.
fd = os.open(os.environ['CREDS_FILE'], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.fchmod(fd, 0o600)
with os.fdopen(fd, 'w') as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
"
    echo " Credentials written to: ${CREDS_FILE}"
    echo "============================================================"
}

main() {
    parse_args "$@"
    load_config
    load_jenkins_connection
    refuse_admin_as_student
    refuse_unsafe_names

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT
    COOKIE_JAR="${TMP_DIR}/cookies"

    provision_all_students
    print_credentials
    write_creds_file
}

main "$@"
