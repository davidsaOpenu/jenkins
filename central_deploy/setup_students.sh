#!/usr/bin/env bash
# Sets up all student users, nodes, and jobs on the central Jenkins.
# Usage: ./setup_students.sh [path/to/students.yaml]
# Safe to re-run — existing users/nodes/jobs are skipped.
set -euo pipefail

err() { echo -e "\033[1;33mERROR: $*\033[0m" >&2; }
hint() { echo -e "\033[1m$*\033[0m" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG="${1:-${SCRIPT_DIR}/students.yaml}"

[[ -f "$CONFIG" ]] || { err "config not found: $CONFIG"; hint "Copy students.yaml.example to students.yaml and fill it in."; exit 1; }

python3 -c "import yaml" 2>/dev/null || { err "pyyaml required — run: pip install pyyaml"; exit 1; }

# Parse entire config in one shot
eval "$(python3 - "$CONFIG" <<'PYEOF'
import yaml, sys

d = yaml.safe_load(open(sys.argv[1]))
print(f'JENKINS_URL="{d["central_url"]}"')
print(f'JENKINS_USER="{d["admin_user"]}"')
print(f'JENKINS_PASS="{d["admin_password"]}"')
print(f'REPO_URL="{d["repo_url"]}"')
print(f'STUDENT_COUNT={len(d["students"])}')
for i, s in enumerate(d["students"]):
    print(f'STUDENT_{i}_NAME="{s["name"]}"')
    print(f'STUDENT_{i}_PROJECT="{s["project"]}"')
    print(f'STUDENT_{i}_PASSWORD="{s["password"]}"')
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

RESULTS=()

for i in $(seq 0 $((STUDENT_COUNT - 1))); do
    eval "NAME=\$STUDENT_${i}_NAME PROJECT=\$STUDENT_${i}_PROJECT PASSWORD=\$STUDENT_${i}_PASSWORD"
    NODE_NAME="${NAME}-vm"
    JOB_NAME="${PROJECT}-${NODE_NAME}"

    # swiftacular/xv6/simulator each need a real Jenkinsfile.student added under
    # jobs/<project>/ before they can be used — see student_deploy/jobs_examples/
    # for reference. Checked for existence below; missing file stops the script.
    case "$PROJECT" in
        swiftacular)       JENKINSFILE="jobs/swiftacular/Jenkinsfile.student" ;;
        xv6)               JENKINSFILE="jobs/xv6-24.04-vm/Jenkinsfile.student" ;;
        simulator)         JENKINSFILE="jobs/simulator-docker-ng-infra/Jenkinsfile.student" ;;
        swiftacular_dummy) JENKINSFILE="jobs/swiftacular-dummy/Jenkinsfile" ;;
        *) err "unknown project '${PROJECT}' for student '${NAME}'"; exit 1 ;;
    esac

    [[ -f "${REPO_ROOT}/${JENKINSFILE}" ]] || {
        err "${JENKINSFILE} not found for project '${PROJECT}' (student '${NAME}')."
        hint "       Add the job file, or use project: swiftacular_dummy for now."
        exit 1
    }

    echo ""
    echo "── ${NAME} (${PROJECT}) ──────────────────────────────────"

    # 1. Create Jenkins user
    echo "  → user '${NAME}'..."
    CRUMB=$(get_crumb)
    USER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "$CRUMB" \
        --data-urlencode "username=${NAME}" \
        --data-urlencode "password1=${PASSWORD}" \
        --data-urlencode "password2=${PASSWORD}" \
        --data-urlencode "fullname=${NAME}" \
        --data-urlencode "email=${NAME}@student.local" \
        "${JENKINS_URL}/securityRealm/createAccountByAdmin")
    [[ "$USER_STATUS" == "302" ]] && echo "    ✓ created" || echo "    ⚠ already exists, skipped"

    # 2. Create agent node
    echo "  → node '${NODE_NAME}'..."
    CRUMB=$(get_crumb)
    NODE_JSON='{
        "name": "'"${NODE_NAME}"'",
        "nodeDescription": "Student VM — '"${NAME}"'",
        "numExecutors": 1,
        "remoteFS": "/var/lib/jenkins-agent",
        "labelString": "'"${NODE_NAME}"'",
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
        -H "$CRUMB" \
        --data-urlencode "json=${NODE_JSON}" \
        "${JENKINS_URL}/computer/doCreateItem?name=${NODE_NAME}&type=hudson.slaves.DumbSlave" \
        && echo "    ✓ created" || echo "    ⚠ already exists, skipped"

    # 3. Fetch agent secret
    SECRET=$(curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        "${JENKINS_URL}/computer/${NODE_NAME}/jenkins-agent.jnlp" \
        | grep -oP '(?<=<argument>)[a-f0-9]{64}(?=</argument>)') \
        || { err "could not fetch secret for ${NODE_NAME}"; exit 1; }

    # 4. Create pipeline job
    echo "  → job '${JOB_NAME}'..."
    JOB_XML="<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin=\"workflow-job\">
  <description>Distributed CI — ${PROJECT} — ${NAME}</description>
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

    CRUMB=$(get_crumb)
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "$CRUMB" \
        -H "Content-Type: application/xml" \
        --data-binary "${JOB_XML}" \
        "${JENKINS_URL}/createItem?name=${JOB_NAME}" \
        && echo "    ✓ created" || echo "    ⚠ already exists, skipped"

    RESULTS+=("${NAME}|${NODE_NAME}|${PROJECT}|${SECRET}|${PASSWORD}")
done

echo ""
echo "============================================================"
echo " Done. Send each student their credentials:"
echo "============================================================"
for entry in "${RESULTS[@]}"; do
    IFS='|' read -r name node project secret password <<< "$entry"
    echo ""
    echo "  Student  : ${name}  (${project})"
    echo "  Jenkins  : ${JENKINS_URL}  user: ${name}  password: ${password}"
    echo "  vault_central_url:          ${JENKINS_URL}"
    echo "  vault_central_agent_name:   ${node}"
    echo "  vault_central_agent_secret: ${secret}"
done
echo ""
echo "============================================================"

# Fresh file every run — overwrites whatever was there before, not appended.
CREDS_FILE="${SCRIPT_DIR}/students_credentials.yaml"
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
