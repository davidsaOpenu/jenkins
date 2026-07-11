#!/usr/bin/env bash
# Builds a fresh, fully-configured Jenkins from scratch and proves the
# Gerrit trigger wiring actually works. Two modes:
#
#   (default)      Self-check — no vault, no real secrets anywhere: hardcoded
#                   admin password, a throwaway generated Gerrit SSH key that
#                   never actually connects to GerritHub, and Step 7's
#                   simulated-event path. This is what cron and Gerrit-
#                   triggered runs use — no human present, nothing to expose.
#   --real-gerrit   Reads central_deploy/roles/jenkins/vars/vault.yml
#                   (ansible-vault encrypted) for the real admin password and
#                   a real GerritHub-registered SSH key, connects for real,
#                   and optionally pushes a real patchset (see
#                   vault_dummy_change_number below). For an instructor
#                   manually standing up a real replacement.
#
# The VM is always left running after a confirmed-good run — ready to serve
# as the central Jenkins immediately (--real-gerrit), or just there to
# inspect (self-check). Use cleanup.sh separately to tear it down.
#
# Non-interactive --real-gerrit (cron/Gerrit): export VAULT_PASSWORD_FILE=/path/to/vault_pass
# Interactive --real-gerrit: just run it, you'll be prompted once.
#
# vault_dummy_change_number (in vault.yml, --real-gerrit only) controls Step
# 7's verification method:
#   - set to a permanent Gerrit change reserved on davidsaOpenu/swiftacular:
#     pushes a fresh, real patchset onto it to exercise the actual Gerrit
#     trigger wiring end-to-end. (Not a comment — gerrit-trigger silently
#     skips comments authored by its own configured user to avoid feedback
#     loops from its own Verified votes; a new patchset has no such
#     restriction, same as running `git review`.)
#   - left blank, or self-check mode: skips GerritHub entirely — instead
#     injects a simulated patchset-created event directly into gerrit-
#     trigger's own processing pipeline (via the Jenkins Script Console), so
#     the same project/branch/event-type matching logic still gets
#     exercised, with zero network calls to GerritHub and no dummy change
#     needed anywhere.
#
# --local-repo (testing only): serve this checkout over a local git daemon
# instead of pointing the dummy job at the real GerritHub master — lets you
# validate Steps 6-7 before this code is ever pushed/merged.
#
# If anything fails along the way, the VM is left running so you can SSH in
# and debug — same as a successful run, just something to go fix first.
set -euo pipefail

# The host environment exports a broken proxy (https_proxy=https://192.114.0.89:80/
# — wrong scheme, and unreachable for private addresses regardless). Everything
# this script curls is a local VM (192.168.100.x) no proxy could ever reach,
# but curl silently honors http_proxy for plain-http URLs: each request hangs
# for minutes against the dead proxy and returns empty — which surfaced as
# json.decoder.JSONDecodeError in Step 6. Strip the whole family.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

title() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo " $1"
    echo "════════════════════════════════════════════════════════════"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Guards against a daily cron self-check and a manual recovery run ever
# overlapping on the same host — released automatically when the script
# exits, whatever the reason.
LOCK_FILE="/tmp/jenkins-dr-run.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "✗ Another run.sh is already in progress (lock: ${LOCK_FILE})"
    exit 1
fi

LOCAL_REPO=false
REAL_GERRIT=false
GIT_DAEMON_PID=""
TMP_CLONE=""
TMP_SSH_CFG=""
TMP_INVENTORY=""
TMP_VAULT_PASS=""
TMP_GERRIT_KEY=""
TMP_EXTRA_VARS=""
TMP_COOKIE_JAR=""
for arg in "$@"; do
    case "$arg" in
        --local-repo)  LOCAL_REPO=true ;;
        --real-gerrit) REAL_GERRIT=true ;;
    esac
done

# Registered before anything (git daemon, VM relay) that could exit early,
# so nothing started below this point can ever leak past a failure.
trap 'rm -f "$TMP_SSH_CFG" "$TMP_INVENTORY" "$TMP_VAULT_PASS" "$TMP_GERRIT_KEY" "${TMP_GERRIT_KEY}.pub" "$TMP_EXTRA_VARS" "$TMP_COOKIE_JAR"; [[ -n "$TMP_CLONE" ]] && rm -rf "$TMP_CLONE"; [[ -n "$GIT_DAEMON_PID" ]] && kill "$GIT_DAEMON_PID" 2>/dev/null; true' EXIT

title "Step 1/8 — Local setup"
mkdir -p "${SCRIPT_DIR}/../swiftacular"
cp "${SCRIPT_DIR}/cleanup.sh" "${SCRIPT_DIR}/../swiftacular/cleanup.sh"
chmod +x "${SCRIPT_DIR}/../swiftacular/cleanup.sh"

if [[ "$LOCAL_REPO" == "true" ]]; then
    echo "→ --local-repo: serving this checkout over a local git daemon..."
    sudo firewall-cmd --add-port=9418/tcp --zone=libvirt 2>/dev/null || true
    touch "${SCRIPT_DIR}/.git/git-daemon-export-ok"
    # pkill only sends the signal, it doesn't wait — a stale daemon from a
    # prior interrupted run can still hold port 9418 for a moment after this
    # returns, so poll until it's actually gone before binding a new one.
    pkill -f "git daemon.*${SCRIPT_DIR}" 2>/dev/null || true
    for _ in $(seq 1 20); do
        ss -tln 2>/dev/null | grep -q ':9418 ' || break
        sleep 0.5
    done
    git daemon --reuseaddr --base-path="$(dirname "$SCRIPT_DIR")" --export-all --port=9418 "$SCRIPT_DIR" &
    GIT_DAEMON_PID=$!
    echo "→ Serving at git://192.168.100.1/jenkins (PID ${GIT_DAEMON_PID})"
fi

# vagrant/libvirt can't nest inside a VM. If this job is executing inside one,
# relay the whole checkout to the physical host and let it do the real work.
if systemd-detect-virt --quiet; then
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
    # `|| RC=$?` (not a bare `RC=$?` after) — under set -e, a failing command
    # on its own line exits the script immediately, skipping the cleanup and
    # exit below entirely. This form captures the failure without tripping it.
    RC=0
    ssh build-host "cd ${REMOTE_DIR} && ${REMOTE_ENV} ./run.sh $*" || RC=$?
    ssh build-host "rm -rf ${REMOTE_DIR}"
    exit $RC
fi

DEPLOY_DIR="central_deploy"
VAGRANTFILE="${DEPLOY_DIR}/Vagrantfile.jenkins"
VAULT_FILE="${DEPLOY_DIR}/roles/jenkins/vars/vault.yml"
DEFAULTS_FILE="${DEPLOY_DIR}/roles/jenkins/defaults/main.yml"
VM_NAME="jenkins-01"
# vagrant-libvirt connects here (Vagrantfile.jenkins sets qemu_use_session =
# false) — bare `virsh` defaults to qemu:///session instead, a completely
# separate per-user scope that never sees this domain. Every virsh call below
# must target this explicitly or it silently checks the wrong libvirt.
LIBVIRT_URI="qemu:///system"
JENKINS_IP="192.168.100.170"
JENKINS_PORT=$(python3 -c "import yaml; print(yaml.safe_load(open('${DEFAULTS_FILE}'))['jenkins_http_port'])")
JENKINS_URL="http://${JENKINS_IP}:${JENKINS_PORT}"
DUMMY_JOB="swiftacular-dummy"

TMP_SSH_CFG=$(mktemp)
TMP_INVENTORY=$(mktemp)
TMP_VAULT_PASS=$(mktemp)
TMP_GERRIT_KEY=$(mktemp)
TMP_COOKIE_JAR=$(mktemp)

title "Step 2/8 — Spawn VM (${VM_NAME})"
# vagrant-libvirt names the domain "<cwd-basename>_<machine-name>" (confirmed
# in practice: "jenkins_jenkins-01", cwd here is always this checkout, cd'd to
# above). Compute that exact name — never a pattern — so cleanup can only ever
# touch this one domain, never another VM sharing this libvirt host.
DOMAIN_NAME="$(basename "$SCRIPT_DIR")_${VM_NAME}"
# A domain from an earlier run can outlive this workspace (e.g. cleanup.sh
# never ran, or ran against different local Vagrant state) and block vagrant
# up with a name collision. This script's job is a fresh build every time, so
# clear any such leftover first rather than fail on it.
if virsh -c "$LIBVIRT_URI" dominfo "$DOMAIN_NAME" &>/dev/null; then
    echo "→ Removing stale libvirt domain '${DOMAIN_NAME}' from a previous run..."
    virsh -c "$LIBVIRT_URI" destroy "$DOMAIN_NAME" 2>/dev/null || true
    virsh -c "$LIBVIRT_URI" undefine "$DOMAIN_NAME" --remove-all-storage 2>/dev/null || true
fi
VAGRANT_VAGRANTFILE="$VAGRANTFILE" vagrant up "$VM_NAME"

title "Step 3/8 — Build Ansible inventory"
VAGRANT_VAGRANTFILE="$VAGRANTFILE" vagrant ssh-config "$VM_NAME" > "$TMP_SSH_CFG"
HOST=$(awk '/HostName/{print $2}' "$TMP_SSH_CFG")
PORT=$(awk '/Port/{print $2}' "$TMP_SSH_CFG")
SSH_USER=$(awk '/User /{print $2}' "$TMP_SSH_CFG")
KEY=$(awk '/IdentityFile/{print $2}' "$TMP_SSH_CFG")
cat > "$TMP_INVENTORY" <<EOF
[jenkins]
${VM_NAME} ansible_host=${HOST} ansible_port=${PORT} ansible_user=${SSH_USER} ansible_ssh_private_key_file=${KEY} ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

title "Step 4/8 — Credentials"
ADMIN_USER="admin"
VAULT_ARGS=()
EXTRA_VARS=()
[[ "$LOCAL_REPO" == "true" ]] && EXTRA_VARS+=(-e "dummy_job_repo_url=git://192.168.100.1/jenkins")

if [[ "$REAL_GERRIT" == "true" ]]; then
    if [[ -n "${VAULT_PASSWORD_FILE:-}" ]]; then
        cp "$VAULT_PASSWORD_FILE" "$TMP_VAULT_PASS"
    else
        read -rsp "Ansible Vault password: " VAULT_PASS
        echo
        printf '%s' "$VAULT_PASS" > "$TMP_VAULT_PASS"
    fi
    VAULT_ARGS+=(--vault-password-file="$TMP_VAULT_PASS")
    EXTRA_VARS+=(-e "vault_in_use=true" -e "gerrit_connect_on_startup=true")

    VAULT_DATA=$(ansible-vault view "$VAULT_FILE" --vault-password-file="$TMP_VAULT_PASS")
    ADMIN_PASS=$(echo "$VAULT_DATA" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['vault_jenkins_admin_password'])")
    GERRIT_USER=$(echo "$VAULT_DATA" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['vault_gerrit_ssh_username'])")
    GERRIT_EMAIL=$(echo "$VAULT_DATA" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('vault_gerrit_email') or '')")
    DUMMY_CHANGE_NUMBER=$(echo "$VAULT_DATA" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('vault_dummy_change_number') or '')")
    echo "$VAULT_DATA" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['vault_gerrit_ssh_private_key'], end='')" > "$TMP_GERRIT_KEY"
else
    echo "→ Self-check mode: hardcoded admin password, throwaway Gerrit key, simulated event — no vault involved"
    ADMIN_PASS="admin1234"
    GERRIT_USER="selfcheck"
    GERRIT_EMAIL=""
    DUMMY_CHANGE_NUMBER=""
    rm -f "$TMP_GERRIT_KEY"
    ssh-keygen -q -t ed25519 -N "" -f "$TMP_GERRIT_KEY"

    # Extra-vars file, not -e key=value, because the key's PEM content is
    # multi-line — ansible-playbook still consumes it fine via -e "@file".
    TMP_EXTRA_VARS=$(mktemp)
    python3 - "$ADMIN_PASS" "$GERRIT_USER" "$TMP_GERRIT_KEY" "$TMP_EXTRA_VARS" <<'PYEOF'
import sys, yaml
admin_pass, gerrit_user, key_file, out_file = sys.argv[1:5]
yaml.safe_dump({
    'vault_in_use': False,
    'gerrit_connect_on_startup': False,
    'jenkins_admin_password': admin_pass,
    'gerrit_ssh_username': gerrit_user,
    'gerrit_ssh_private_key': open(key_file).read(),
}, open(out_file, 'w'))
PYEOF
    EXTRA_VARS+=(-e "@${TMP_EXTRA_VARS}")
fi
chmod 600 "$TMP_GERRIT_KEY"

if [[ -n "$DUMMY_CHANGE_NUMBER" && ! "$DUMMY_CHANGE_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "✗ vault_dummy_change_number must be numeric, got: ${DUMMY_CHANGE_NUMBER}"
    exit 1
fi
# Only the real-Gerrit-push path needs a registered email — the simulated-
# event path (blank vault_dummy_change_number, always true in self-check
# mode) never touches GerritHub at all.
if [[ -n "$DUMMY_CHANGE_NUMBER" && -z "$GERRIT_EMAIL" ]]; then
    echo "✗ vault_dummy_change_number is set but vault_gerrit_email is blank — required to push the verification patchset"
    exit 1
fi

title "Step 5/8 — Deploy Jenkins (plugins, Gerrit connection, jobs)"
ansible-playbook -i "$TMP_INVENTORY" -b \
    "${VAULT_ARGS[@]}" \
    "${EXTRA_VARS[@]}" \
    "${DEPLOY_DIR}/deploy_jenkins.yml"

title "Step 6/8 — Register Gerrit trigger (first build)"
# Jenkins only registers a pipeline's triggers{} block after it has run once.
# swiftacular-dummy is recreated fresh by JCasC on every run, so without this,
# the real Gerrit event in the next step would silently trigger nothing.
get_crumb() {
    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -c "$TMP_COOKIE_JAR" -b "$TMP_COOKIE_JAR" \
        "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])"
}
# Build numbers persist across job recreations (only config.xml gets wiped
# by the ansible role, not the builds/ history) — so "a build exists" isn't
# proof THIS run's trigger fired one. Capture the last known number first
# and wait for it to change, not just be >= 1.
BEFORE_REGISTER=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${DUMMY_JOB}/lastBuild/buildNumber" 2>/dev/null || echo 0)

# Plain /build, not /buildWithParameters — Jenkins doesn't know this job
# has parameters until this very first build evaluates the Jenkinsfile's
# own parameters{} block; /buildWithParameters 400s ("not parameterized")
# on a job that has never run. The Jenkinsfile's own defaults apply anyway.
CRUMB=$(get_crumb)
curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -c "$TMP_COOKIE_JAR" -b "$TMP_COOKIE_JAR" -H "$CRUMB" \
    -X POST "${JENKINS_URL}/job/${DUMMY_JOB}/build"
echo "→ Waiting for the first build to register the trigger..."
REGISTER_BUILD="$BEFORE_REGISTER"
for _ in $(seq 1 30); do
    sleep 5
    REGISTER_BUILD=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${DUMMY_JOB}/lastBuild/buildNumber" 2>/dev/null || echo "$BEFORE_REGISTER")
    [[ "$REGISTER_BUILD" != "$BEFORE_REGISTER" ]] && break
done
if [[ "$REGISTER_BUILD" == "$BEFORE_REGISTER" ]]; then
    echo "✗ First build never ran — trigger registration failed"
    exit 1
fi
echo "→ Trigger registered (build #${REGISTER_BUILD})"

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

BEFORE="$REGISTER_BUILD"

if [[ -z "$DUMMY_CHANGE_NUMBER" ]]; then
    title "Step 7/8 — Simulate Gerrit event directly (no GerritHub)"
    # Injects a real patchset-created event straight into gerrit-trigger's own
    # processing pipeline (GerritHandler.post) via the Jenkins Script Console —
    # exercises the actual project/branch/event-type matching logic, with zero
    # network calls to GerritHub and no dummy change required anywhere.

    # Self-check never opens a real connection to GerritHub (noConnectionOnStartup),
    # so nothing else here would ever notice a firewall/DNS/GerritHub outage.
    # This needs no credentials — just proves the network path is still open.
    if [[ "$REAL_GERRIT" != "true" ]]; then
        echo "→ Checking network reachability to review.gerrithub.io:29418..."
        if nc -z -w5 review.gerrithub.io 29418; then
            echo "  ✓ reachable"
        else
            echo "✗ Cannot reach review.gerrithub.io:29418 — check firewall/DNS/GerritHub status"
            exit 1
        fi
    fi

    echo "→ Injecting a simulated patchset-created event into gerrit-trigger..."
    CRUMB=$(get_crumb)
    EVENT_JSON=$(cat <<JSONEOF
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
    GROOVY_SCRIPT="import com.sonyericsson.hudson.plugins.gerrit.trigger.PluginImpl
import net.sf.json.JSONObject
def json = JSONObject.fromObject('''${EVENT_JSON}''')
PluginImpl.getInstance().getHandler().post(json)"

    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -c "$TMP_COOKIE_JAR" -b "$TMP_COOKIE_JAR" -H "$CRUMB" \
        --data-urlencode "script=${GROOVY_SCRIPT}" \
        "${JENKINS_URL}/scriptText" > /dev/null

    echo "→ Waiting for ${DUMMY_JOB} to trigger and finish..."
    if ! wait_for_new_build "$BEFORE"; then
        echo "✗ Simulated event never resulted in a new build"
        exit 1
    fi
else
    title "Step 7/8 — Trigger via REAL Gerrit event and wait"
    echo "→ Pushing a fresh patchset onto swiftacular change ${DUMMY_CHANGE_NUMBER}..."
    REF_PREFIX=$(printf '%02d' $((DUMMY_CHANGE_NUMBER % 100)))
    GERRIT_REMOTE="ssh://${GERRIT_USER}@review.gerrithub.io:29418/davidsaOpenu/swiftacular"
    export GIT_SSH_COMMAND="ssh -i ${TMP_GERRIT_KEY} -o StrictHostKeyChecking=no -p 29418"

    # git fetch needs an exact ref, not a bare wildcard — resolve the current
    # highest patchset number for this change first via ls-remote.
    LATEST_REF=$(git ls-remote "$GERRIT_REMOTE" "refs/changes/${REF_PREFIX}/${DUMMY_CHANGE_NUMBER}/*" \
        | sort -t/ -k5 -n | tail -1 | awk '{print $2}')
    if [[ -z "$LATEST_REF" ]]; then
        echo "✗ Could not find any patchset ref for change ${DUMMY_CHANGE_NUMBER}"
        exit 1
    fi

    TMP_CLONE=$(mktemp -d)
    git -C "$TMP_CLONE" init -q
    git -C "$TMP_CLONE" remote add origin "$GERRIT_REMOTE"
    git -C "$TMP_CLONE" fetch -q origin "$LATEST_REF"
    git -C "$TMP_CLONE" checkout -q FETCH_HEAD
    git -C "$TMP_CLONE" config user.email "$GERRIT_EMAIL"
    git -C "$TMP_CLONE" config user.name "$GERRIT_USER"
    # A real (trivial) file change, not an empty commit — mirrors an actual
    # `change file -> add -> commit -> git review` cycle.
    echo "CI verification touch: $(date -u +%FT%TZ)" >> "$TMP_CLONE/.gerrit-trigger-check"
    git -C "$TMP_CLONE" add -A
    git -C "$TMP_CLONE" commit -q --amend --no-edit
    git -C "$TMP_CLONE" push -q origin HEAD:refs/for/master
    unset GIT_SSH_COMMAND
    rm -rf "$TMP_CLONE"
    TMP_CLONE=""

    echo "→ Waiting for ${DUMMY_JOB} to trigger and finish..."
    if ! wait_for_new_build "$BEFORE"; then
        echo "✗ Trigger never resulted in a new build"
        exit 1
    fi
fi

RESULT=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${DUMMY_JOB}/${NUM}/api/json" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")
echo "→ Build #${NUM} result: ${RESULT}"
[[ "$RESULT" == "SUCCESS" ]] || { echo "✗ Dummy job did not succeed"; exit 1; }

title "Step 8/8 — Done"
if [[ "$REAL_GERRIT" == "true" ]]; then
    echo "✓ Fresh Jenkins verified and ready to replace the central instance."
else
    echo "✓ Self-check passed — deploy automation and Gerrit trigger logic verified."
    echo "  (admin1234 / throwaway Gerrit key — not meant to serve as production)"
fi
echo "  URL: ${JENKINS_URL}  user: ${ADMIN_USER}"
echo "  (VM left running — use cleanup.sh to tear it down)"
