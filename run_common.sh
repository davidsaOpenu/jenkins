#!/usr/bin/env bash
# Shared functions for run.sh (self-check) and run_real_gerrit.sh (manual
# real-Gerrit deploy). Sourced only — not meant to be executed directly.
#
# Functions below read shared config (SCRIPT_DIR, DEPLOY_DIR, JENKINS_URL,
# TMP_* paths, etc.) as globals set by common_setup() — only per-call values
# (e.g. a build number) are passed as parameters.

# The host environment exports a broken proxy (https_proxy=https://192.114.0.89:80/
# — wrong scheme, and unreachable for private addresses regardless). Everything
# this script curls is a local VM (192.168.100.x) no proxy could ever reach,
# but curl silently honors http_proxy for plain-http URLs: each request hangs
# for minutes against the dead proxy and returns empty. Strip the whole family.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

# Defaults to false: run_real_gerrit.sh has no --local-repo flag and never sets this.
LOCAL_REPO="${LOCAL_REPO:-false}"

title() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo " $1"
    echo "════════════════════════════════════════════════════════════"
}

# vagrant/libvirt can't nest inside a VM. If run.sh/run_real_gerrit.sh is
# executing inside one, relay the whole checkout to the physical host and
# let it do the real work there instead.
relay_to_build_host_and_exit() {
    echo "→ Running inside a VM — delegating to build-host..."
    REMOTE_DIR="/tmp/jenkins-run-$$"
    ssh build-host "mkdir -p ${REMOTE_DIR}"
    rsync -a --exclude '.git' "${SCRIPT_DIR}/" "build-host:${REMOTE_DIR}/"
    if [[ -n "${VAULT_PASSWORD_FILE:-}" ]]; then
        scp -q "$VAULT_PASSWORD_FILE" "build-host:${REMOTE_DIR}/.vault_pass"
        REMOTE_ENV="VAULT_PASSWORD_FILE=${REMOTE_DIR}/.vault_pass"
    else
        REMOTE_ENV=""
    fi
    # `|| rc=$?` (not a bare `rc=$?` after) — under set -e, a failing command
    # on its own line exits the script immediately, skipping the cleanup and
    # exit below entirely. This form captures the failure without tripping it.
    local rc=0
    ssh build-host "cd ${REMOTE_DIR} && ${REMOTE_ENV} ./$(basename "$0") $*" || rc=$?
    ssh build-host "rm -rf ${REMOTE_DIR}"
    exit "$rc"
}

# Prologue every run needs, in this fixed order: lock, trap, Step 1's local
# setup, then the VM-relay check.
common_setup() {
    cd "$SCRIPT_DIR"

    # Guards against a daily cron self-check and a manual recovery run ever
    # overlapping on the same host — released automatically when the script
    # exits, whatever the reason.
    LOCK_FILE="/tmp/jenkins-dr-run.lock"
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        echo "✗ Another run is already in progress (lock: ${LOCK_FILE})"
        exit 1
    fi

    GIT_DAEMON_PID=""
    TMP_CLONE=""
    TMP_SSH_CFG=""
    TMP_INVENTORY=""
    TMP_VAULT_PASS=""
    TMP_GERRIT_KEY=""
    TMP_EXTRA_VARS=""
    TMP_COOKIE_JAR=""

    # Registered before anything (git daemon, VM relay) that could exit early,
    # so nothing started below this point can ever leak past a failure.
    trap 'rm -f "$TMP_SSH_CFG" "$TMP_INVENTORY" "$TMP_VAULT_PASS" "$TMP_GERRIT_KEY" "${TMP_GERRIT_KEY}.pub" "$TMP_EXTRA_VARS" "$TMP_COOKIE_JAR"; [[ -n "$TMP_CLONE" ]] && rm -rf "$TMP_CLONE"; [[ -n "$GIT_DAEMON_PID" ]] && kill "$GIT_DAEMON_PID" 2>/dev/null; true' EXIT

    title "Step 1/8 — Local setup"
    mkdir -p "${SCRIPT_DIR}/../swiftacular"
    cp "${SCRIPT_DIR}/cleanup.sh" "${SCRIPT_DIR}/../swiftacular/cleanup.sh"
    chmod +x "${SCRIPT_DIR}/../swiftacular/cleanup.sh"

    [[ "$LOCAL_REPO" == "true" ]] && start_local_git_daemon

    systemd-detect-virt --quiet && relay_to_build_host_and_exit "$@"

    DEPLOY_DIR="central_deploy"
    VAGRANTFILE="${DEPLOY_DIR}/Vagrantfile.jenkins"
    VAULT_FILE="${DEPLOY_DIR}/roles/jenkins/vars/vault.yml"
    DEFAULTS_FILE="${DEPLOY_DIR}/roles/jenkins/defaults/main.yml"
    VM_NAME="jenkins-01"
    # vagrant-libvirt connects here (Vagrantfile.jenkins sets qemu_use_session =
    # false) — bare `virsh` defaults to qemu:///session instead, a completely
    # separate per-user scope that never sees this domain.
    LIBVIRT_URI="qemu:///system"
    JENKINS_IP="192.168.100.170"
    JENKINS_PORT=$(python3 -c "import yaml; print(yaml.safe_load(open('${DEFAULTS_FILE}'))['jenkins_http_port'])")
    JENKINS_URL="http://${JENKINS_IP}:${JENKINS_PORT}"
    DUMMY_JOB="swiftacular-dummy"
    ADMIN_USER="admin"

    TMP_SSH_CFG=$(mktemp)
    TMP_INVENTORY=$(mktemp)
    TMP_VAULT_PASS=$(mktemp)
    TMP_GERRIT_KEY=$(mktemp)
    TMP_COOKIE_JAR=$(mktemp)
}

spawn_vm() {
    title "Step 2/8 — Spawn VM (${VM_NAME})"
    # vagrant-libvirt names domains "<cwd-basename>_<machine-name>"; compute the
    # exact name so cleanup never touches an unrelated VM on this libvirt host.
    DOMAIN_NAME="$(basename "$SCRIPT_DIR")_${VM_NAME}"
    if virsh -c "$LIBVIRT_URI" dominfo "$DOMAIN_NAME" &>/dev/null; then
        echo "→ Removing stale libvirt domain '${DOMAIN_NAME}' from a previous run..."
        virsh -c "$LIBVIRT_URI" destroy "$DOMAIN_NAME" 2>/dev/null || true
        virsh -c "$LIBVIRT_URI" undefine "$DOMAIN_NAME" --remove-all-storage 2>/dev/null || true
    fi
    VAGRANT_VAGRANTFILE="$VAGRANTFILE" vagrant up "$VM_NAME"
}

build_inventory() {
    title "Step 3/8 — Build Ansible inventory"
    VAGRANT_VAGRANTFILE="$VAGRANTFILE" vagrant ssh-config "$VM_NAME" > "$TMP_SSH_CFG"
    local host port ssh_user key
    host=$(awk '/HostName/{print $2}' "$TMP_SSH_CFG")
    port=$(awk '/Port/{print $2}' "$TMP_SSH_CFG")
    ssh_user=$(awk '/User /{print $2}' "$TMP_SSH_CFG")
    key=$(awk '/IdentityFile/{print $2}' "$TMP_SSH_CFG")
    cat > "$TMP_INVENTORY" <<EOF
[jenkins]
${VM_NAME} ansible_host=${host} ansible_port=${port} ansible_user=${ssh_user} ansible_ssh_private_key_file=${key} ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF
}

deploy_jenkins() {
    title "Step 5/8 — Deploy Jenkins (plugins, Gerrit connection, jobs)"
    ansible-playbook -i "$TMP_INVENTORY" -b \
        "${VAULT_ARGS[@]}" \
        "${EXTRA_VARS[@]}" \
        "${DEPLOY_DIR}/deploy_jenkins.yml"
}

get_crumb() {
    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -c "$TMP_COOKIE_JAR" -b "$TMP_COOKIE_JAR" \
        "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])"
}

# Jenkins only registers a pipeline's triggers{} block after it has run once.
# swiftacular-dummy is recreated fresh by JCasC on every run, so without this,
# a later Gerrit event would silently trigger nothing. Sets REGISTER_BUILD.
register_gerrit_trigger() {
    title "Step 6/8 — Register Gerrit trigger (first build)"
    # Build numbers persist across job recreations (only config.xml gets wiped
    # by the ansible role, not the builds/ history) — so "a build exists" isn't
    # proof THIS run's trigger fired one. Capture the last known number first
    # and wait for it to change, not just be >= 1.
    local before_register
    before_register=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${DUMMY_JOB}/lastBuild/buildNumber" 2>/dev/null || echo 0)

    # Plain /build, not /buildWithParameters — Jenkins doesn't know this job
    # has parameters until this very first build evaluates the Jenkinsfile's
    # own parameters{} block; /buildWithParameters 400s ("not parameterized")
    # on a job that has never run. The Jenkinsfile's own defaults apply anyway.
    local crumb
    crumb=$(get_crumb)
    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -c "$TMP_COOKIE_JAR" -b "$TMP_COOKIE_JAR" -H "$crumb" \
        -X POST "${JENKINS_URL}/job/${DUMMY_JOB}/build"
    echo "→ Waiting for the first build to register the trigger..."
    REGISTER_BUILD="$before_register"
    for _ in $(seq 1 30); do
        sleep 5
        REGISTER_BUILD=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${DUMMY_JOB}/lastBuild/buildNumber" 2>/dev/null || echo "$before_register")
        [[ "$REGISTER_BUILD" != "$before_register" ]] && break
    done
    if [[ "$REGISTER_BUILD" == "$before_register" ]]; then
        echo "✗ First build never ran — trigger registration failed"
        exit 1
    fi
    echo "→ Trigger registered (build #${REGISTER_BUILD})"
}

# Polls until lastBuild's number changes from $1 and that build finishes.
# Sets NUM as a side effect; returns non-zero if it never changed.
wait_for_new_build() {
    local before="$1"
    NUM="$before"
    for _ in $(seq 1 60); do
        sleep 5
        NUM=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${DUMMY_JOB}/lastBuild/buildNumber" 2>/dev/null || echo "$before")
        [[ "$NUM" == "$before" ]] && continue
        local building
        building=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${DUMMY_JOB}/${NUM}/api/json" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['building'])")
        [[ "$building" == "False" ]] && break
    done
    [[ "$NUM" != "$before" ]]
}

# Injects a real patchset-created event straight into gerrit-trigger's own
# processing pipeline (GerritHandler.post) via the Jenkins Script Console —
# exercises the actual project/branch/event-type matching logic, with zero
# network calls to GerritHub and no dummy change required anywhere. Used by
# both scripts: self-check always, real-gerrit when no change number is set.
simulate_gerrit_event() {
    local before="$1"
    echo "→ Injecting a simulated patchset-created event into gerrit-trigger..."
    local crumb
    crumb=$(get_crumb)
    local event_json
    event_json=$(cat <<JSONEOF
{
  "type": "patchset-created",
  "change": {
    "project": "davidsaOpenu/swiftacular",
    "branch": "master",
    "id": "Isimulatedeventfortriggerverification01",
    "number": "999999",
    "subject": "Simulated event for trigger verification",
    "owner": {"name": "${GERRIT_USER}", "username": "${GERRIT_USER}"},
    "url": "https://review.gerrithub.io/c/davidsaOpenu/swiftacular/+/999999"
  },
  "patchSet": {
    "number": "1",
    "revision": "0000000000000000000000000000000000000000",
    "ref": "refs/changes/99/999999/1",
    "uploader": {"name": "${GERRIT_USER}", "username": "${GERRIT_USER}"},
    "createdOn": $(date +%s)
  },
  "uploader": {"name": "${GERRIT_USER}", "username": "${GERRIT_USER}"},
  "eventCreatedOn": $(date +%s)
}
JSONEOF
)
    local groovy_script="import com.sonyericsson.hudson.plugins.gerrit.trigger.PluginImpl
import net.sf.json.JSONObject
def json = JSONObject.fromObject('''${event_json}''')
PluginImpl.getInstance().getHandler().post(json)"

    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -c "$TMP_COOKIE_JAR" -b "$TMP_COOKIE_JAR" -H "$crumb" \
        --data-urlencode "script=${groovy_script}" \
        "${JENKINS_URL}/scriptText" > /dev/null

    echo "→ Waiting for ${DUMMY_JOB} to trigger and finish..."
    if ! wait_for_new_build "$before"; then
        echo "✗ Simulated event never resulted in a new build"
        exit 1
    fi
}

# The VM is torn down right after this script exits, taking the build's
# console log with it — dump it into THIS log first, or a failure here is
# undiagnosable. Reads NUM (set by wait_for_new_build).
report_build_result() {
    local result
    result=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${DUMMY_JOB}/${NUM}/api/json" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")
    echo "→ Build #${NUM} result: ${result}"
    if [[ "$result" != "SUCCESS" ]]; then
        echo "✗ Dummy job did not succeed — console log of build #${NUM} follows:"
        echo "──────────────────────────────────────────────────────────"
        curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
            "${JENKINS_URL}/job/${DUMMY_JOB}/${NUM}/consoleText" \
            || echo "(could not fetch console log)"
        echo "──────────────────────────────────────────────────────────"
        exit 1
    fi
}

print_final_status() {
    local mode_label="$1"
    title "Step 8/8 — Done"
    echo "$mode_label"
    echo "  URL: ${JENKINS_URL}  user: ${ADMIN_USER}"
    echo "  (VM left running — use cleanup.sh to tear it down)"
}
