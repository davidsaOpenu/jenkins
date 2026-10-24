#!/usr/bin/env bash
# Creates the real CI jobs on a disaster-recovery Jenkins: one pipeline job
# per jobs/<name>/Jenkinsfile in this repo. Disaster-recovery path only —
# run by `setup_central.sh … --with-repo-jobs`, never by CI's run.sh.
#
#   sudo ./central_deploy/create_repo_jobs.sh <gerrit_central.yml> [--repo-url URL] [--branch BRANCH]
#
# Each job is "Pipeline script from SCM": it reads jobs/<name>/Jenkinsfile
# from the jenkins repo on GerritHub (default
# https://review.gerrithub.io/davidsaOpenu/jenkins, branch master) at every
# build — so a merged Jenkinsfile change takes effect on the next build,
# no redeploy. Only the list of jobs comes from this checkout: re-run after
# adding a jobs/<name>/ folder.
#
# A pipeline's triggers{} (Gerrit, cron) only register when it runs, so a
# new job is "primed": a build is started and aborted as soon as the
# pipeline has been read — before any stage does real work. Twice for
# parameterized jobs: their first-ever run sees no parameter values yet
# (the Jenkinsfiles build the Gerrit branch pattern from params.GERRIT_BRANCH),
# the second registers the defaults. Jobs already up to date are skipped.
#
# jenkins-dr-test is not touched: it's defined by JCasC (CI's test job).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "${REPO_ROOT}/deploy_verify.sh"
source "${SCRIPT_DIR}/central_lib.sh"
# curl_auth_config: credentials to curl on stdin, never in argv (visible to
# every local user via ps).
source "${REPO_ROOT}/scripts/sudo/gerrit_key_lib.sh"

unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

SKIP_JOBS=(jenkins-dr-test)
GENERATED_ADMIN_PASSWORD_FILE="/etc/jenkins-dr/admin_password"

usage() {
    echo "Usage: sudo $0 <path-to-gerrit_central.yml> [--repo-url URL] [--branch BRANCH]" >&2
    exit 1
}

parse_args() {
    ACCOUNTS_FILE=""
    JOBS_REPO_URL="https://review.gerrithub.io/davidsaOpenu/jenkins"
    JOBS_BRANCH="master"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-url) [[ $# -ge 2 ]] || usage; JOBS_REPO_URL="$2"; shift 2 ;;
            --branch)   [[ $# -ge 2 ]] || usage; JOBS_BRANCH="$2"; shift 2 ;;
            -*) usage ;;
            *) [[ -z "$ACCOUNTS_FILE" ]] || usage; ACCOUNTS_FILE="$1"; shift ;;
        esac
    done
    [[ -n "$ACCOUNTS_FILE" && -f "$ACCOUNTS_FILE" ]] || usage
}

# curl as the Jenkins admin, credentials via a config on an fd — not argv.
jcurl() {
    curl -sS -K <(curl_auth_config "$ADMIN_USER" "$ADMIN_PASS") \
        -c "${WORKDIR}/cookies" -b "${WORKDIR}/cookies" "$@"
}

crumb_header() {
    jcurl -f "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])"
}

# POSTs to a Jenkins path with a fresh crumb; prints the HTTP status.
jpost() {
    local path="$1"; shift
    jcurl -o /dev/null -w '%{http_code}' -H "$(crumb_header)" -X POST "$@" "${JENKINS_URL}${path}"
}

job_names() {
    local dir name skip
    for dir in "${REPO_ROOT}"/jobs/*/; do
        name="$(basename "$dir")"
        [[ -f "${dir}Jenkinsfile" ]] || continue
        for skip in "${SKIP_JOBS[@]}"; do
            [[ "$name" == "$skip" ]] && continue 2
        done
        echo "$name"
    done
}

job_xml() {
    python3 - "$1" "$JOBS_REPO_URL" "$JOBS_BRANCH" <<'PYEOF'
import sys
from xml.sax.saxutils import escape as e
name, url, branch = sys.argv[1:4]
print(f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>{e(f"Pipeline from jobs/{name}/Jenkinsfile in {url} ({branch}). Created by central_deploy/create_repo_jobs.sh — edit the Jenkinsfile, not this job.")}</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>{e(url)}</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>{e('*/' + branch)}</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>{e(f"jobs/{name}/Jenkinsfile")}</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>""")
PYEOF
}

# "missing", "same" (already reads this Jenkinsfile from this repo/branch),
# or "differs".
job_state() {
    local name="$1" xml
    xml=$(jcurl -f "${JENKINS_URL}/job/${name}/config.xml" 2>/dev/null) || { echo missing; return; }
    python3 -c '
import sys, xml.etree.ElementTree as ET
name, url, branch = sys.argv[1:4]
d = ET.fromstring(sys.stdin.read().encode()).find("definition")
ok = (d is not None and d.get("class", "").endswith("CpsScmFlowDefinition")
      and d.findtext("scriptPath") == f"jobs/{name}/Jenkinsfile"
      and d.findtext(".//userRemoteConfigs//url") == url
      and d.findtext(".//branches//name") in (branch, "*/" + branch))
print("same" if ok else "differs")
' "$name" "$JOBS_REPO_URL" "$JOBS_BRANCH" <<< "$xml"
}

job_properties() {
    jcurl -f "${JENKINS_URL}/job/${1}/api/json?tree=property%5B_class%5D" 2>/dev/null || echo '{}'
}
has_triggers() { job_properties "$1" | grep -q 'PipelineTriggersJobProperty'; }
has_params()   { job_properties "$1" | grep -q 'ParametersDefinitionProperty'; }

last_build() {
    jcurl -f "${JENKINS_URL}/job/${1}/lastBuild/buildNumber" 2>/dev/null || echo 0
}

is_building() {
    jcurl -f "${JENKINS_URL}/job/${1}/${2}/api/json?tree=building" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['building'])" 2>/dev/null || echo False
}

# One priming build: start it, wait until the pipeline definition has been
# read (its first node/stage step appears — job properties, parameters and
# triggers are applied before that), then abort it.
prime_once() {
    local name="$1" before number code i console
    before=$(last_build "$name")
    if has_params "$name"; then
        code=$(jpost "/job/${name}/buildWithParameters")
    else
        code=$(jpost "/job/${name}/build")
    fi
    [[ "$code" == 201 ]] || { echo "  ✗ couldn't start a build of ${name} (HTTP ${code})" >&2; return 1; }

    number="$before"
    for i in $(seq 1 60); do
        number=$(last_build "$name")
        [[ "$number" != "$before" ]] && break
        sleep 2
    done
    [[ "$number" != "$before" ]] || { echo "  ✗ ${name}: the build never left the queue" >&2; return 1; }

    for i in $(seq 1 90); do
        console=$(jcurl -f "${JENKINS_URL}/job/${name}/${number}/consoleText" 2>/dev/null || true)
        if grep -qE '^\[Pipeline\] (node|stage)' <<< "$console"; then
            break
        fi
        if [[ "$(is_building "$name" "$number")" == False ]]; then
            echo "  ✗ ${name} build #${number} ended before the pipeline started — its Jenkinsfile couldn't be loaded:" >&2
            tail -n 15 <<< "$console" | sed 's/^/      /' >&2
            return 1
        fi
        sleep 2
    done

    jpost "/job/${name}/${number}/stop" >/dev/null || true
    for i in $(seq 1 30); do
        [[ "$(is_building "$name" "$number")" == False ]] && break
        sleep 2
    done
    echo "  (priming build #${number} aborted)"
}

prime_job() {
    local name="$1" had_params=false
    has_params "$name" && had_params=true
    echo "→ Priming ${name}'s triggers..."
    prime_once "$name" || return 1
    if [[ "$had_params" == false ]] && has_params "$name"; then
        # First-ever run only defined the parameters (the branch pattern
        # came out as "null"); this one registers them with their defaults.
        prime_once "$name" || return 1
    fi
    if has_triggers "$name"; then
        echo "  ✓ ${name}: triggers registered"
    else
        echo "  ⚠ ${name}: no triggers registered (its Jenkinsfile may define none)"
    fi
}

main() {
    parse_args "$@"
    if [[ "$EUID" -ne 0 ]]; then
        echo "✗ Must run as root: sudo $0 $*" >&2
        exit 1
    fi
    HOME="$(getent passwd root | cut -d: -f6)"
    export HOME

    load_central_account "$ACCOUNTS_FILE" >/dev/null
    resolve_jenkins_url >/dev/null
    ADMIN_USER="$CENTRAL_JENKINS_ADMIN_USER"
    ADMIN_PASS="${CENTRAL_JENKINS_ADMIN_PASSWORD:-$(cat "$GENERATED_ADMIN_PASSWORD_FILE" 2>/dev/null || true)}"
    [[ -n "$ADMIN_PASS" ]] || { echo "✗ No admin password: set jenkins_admin_password or deploy first" >&2; exit 1; }
    JENKINS_URL="http://127.0.0.1:${JENKINS_INTERNAL_PORT}${JENKINS_PREFIX}"
    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT

    jcurl -f -o /dev/null "${JENKINS_URL}/api/json" \
        || { echo "✗ Can't log in to Jenkins at ${JENKINS_URL} as ${ADMIN_USER} — is it deployed and running?" >&2; exit 1; }

    echo "── Jobs from ${REPO_ROOT}/jobs → ${JOBS_REPO_URL} (${JOBS_BRANCH})"
    local name state code failed=() created=() updated=() unchanged=()
    while read -r name; do
        state=$(job_state "$name")
        case "$state" in
            missing)
                code=$(jpost "/createItem?name=${name}" -H 'Content-Type: application/xml' --data-binary @<(job_xml "$name"))
                [[ "$code" == 200 ]] || { echo "  ✗ creating ${name} failed (HTTP ${code})" >&2; failed+=("$name"); continue; }
                echo "→ Created ${name}"
                created+=("$name")
                ;;
            differs)
                code=$(jpost "/job/${name}/config.xml" -H 'Content-Type: application/xml' --data-binary @<(job_xml "$name"))
                [[ "$code" == 200 ]] || { echo "  ✗ updating ${name} failed (HTTP ${code})" >&2; failed+=("$name"); continue; }
                echo "→ Updated ${name} (it pointed elsewhere)"
                updated+=("$name")
                ;;
            same)
                if has_triggers "$name"; then
                    unchanged+=("$name")
                    continue
                fi
                ;;
        esac
        prime_job "$name" || failed+=("$name")
    done < <(job_names)

    echo ""
    echo "Jobs — created: ${created[*]:-none}; updated: ${updated[*]:-none}; already up to date: ${unchanged[*]:-none}"
    if [[ ${#failed[@]} -gt 0 ]]; then
        echo "✗ Failed: ${failed[*]}" >&2
        exit 1
    fi
}

main "$@"
