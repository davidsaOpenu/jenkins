#!/usr/bin/env bash
# Sets up all student users, nodes, and jobs on the central Jenkins.
# Usage: ./setup_students.sh [path/to/students.yaml] [path/to/creds_output.yaml]
# Safe to re-run — existing users/nodes/jobs are skipped.
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
print(f'REPO_URL\t{d["repo_url"]}')
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

# swiftacular/xv6/simulator each need a real Jenkinsfile.student added under
# jobs/<project>/ before they can be used — see student_deploy/jobs_examples/
# for reference. Sets JENKINSFILE, fails if the file doesn't exist.
resolve_jenkinsfile() {
    local project="$1" name="$2"
    case "$project" in
        swiftacular)       JENKINSFILE="jobs/swiftacular/Jenkinsfile.student" ;;
        xv6)               JENKINSFILE="jobs/xv6-24.04-vm/Jenkinsfile.student" ;;
        simulator)         JENKINSFILE="jobs/simulator-docker-ng-infra/Jenkinsfile.student" ;;
        swiftacular_dummy) JENKINSFILE="jobs/swiftacular-dummy/Jenkinsfile" ;;
        *) err "unknown project '${project}' for student '${name}'"; exit 1 ;;
    esac
    [[ -f "${REPO_ROOT}/${JENKINSFILE}" ]] || {
        err "${JENKINSFILE} not found for project '${project}' (student '${name}')."
        hint "       Add the job file, or use project: swiftacular_dummy for now."
        exit 1
    }
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
    # re-renders the same form (HTTP 200) with that specific message when
    # it is; anything else is a real failure that was previously getting
    # silently swallowed as if the user already existed.
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
    # Label must be sanitize_label(name) — no "-vm" suffix — to match what
    # jobs/swiftacular-dummy/Jenkinsfile's agentLabel() looks up at trigger
    # time. This is the fourth intentional copy of that one-line sed
    # transform (see deploy_verify.sh's sanitize_label() for the other three).
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

create_pipeline_job() {
    local name="$1" project="$2" job_name="$3"
    echo "  → job '${job_name}'..."
    local job_xml="<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin=\"workflow-job\">
  <description>Distributed CI — ${project} — ${name}</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>GERRIT_REFSPEC</name>
          <defaultValue>refs/heads/master</defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>GERRIT_BRANCH</name>
          <defaultValue>master</defaultValue>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class=\"org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition\">
    <scm class=\"hudson.plugins.git.GitSCM\">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>${REPO_URL}</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/master</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>${JENKINSFILE}</scriptPath>
    <lightweight>true</lightweight>
  </definition>
</flow-definition>"

    local crumb
    crumb=$(get_crumb)
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "$crumb" \
        -H "Content-Type: application/xml" \
        --data-binary "${job_xml}" \
        "${JENKINS_URL}/createItem?name=${job_name}" \
        && echo "    ✓ created" || echo "    ⚠ already exists, skipped"
}

# Full per-student provisioning: user + node + secret + job. Appends a
# result entry to the global RESULTS array.
provision_student() {
    local name="$1" project="$2" password="$3"
    local node_name="${name}-vm"
    local job_name="${project}-${node_name}"

    resolve_jenkinsfile "$project" "$name"

    echo ""
    echo "── ${name} (${project}) ──────────────────────────────────"

    create_student_user "$name" "$password"
    create_agent_node "$name" "$node_name"
    fetch_agent_secret "$node_name"
    create_pipeline_job "$name" "$project" "$job_name"

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
