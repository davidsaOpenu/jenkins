#!/usr/bin/env bash
# Shared Gerrit-trigger verification + credential-loading functions. Sourced
# only, by deploy_central_jenkins.sh and run.sh, which set the shared
# globals these read: JENKINS_URL, ADMIN_USER/PASS, WORKDIR.

get_crumb() {
    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -c "${WORKDIR}/cookies" -b "${WORKDIR}/cookies" \
        "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])"
}

# job_name's current lastBuild number (0 if it has none yet).
current_build_number() {
    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${1}/lastBuild/buildNumber" 2>/dev/null || echo 0
}

# Jenkins only registers a pipeline's triggers{} block after it has run
# once — call this once per job, not once per event. Sets REGISTER_BUILD.
register_gerrit_trigger() {
    local job_name="$1"
    echo "→ Registering Gerrit trigger for ${job_name}..."
    local before_register
    before_register=$(current_build_number "$job_name")
    echo "  (current lastBuild: #${before_register})"

    # Plain /build works for a genuinely fresh job — Jenkins doesn't know it
    # has parameters until its first build evaluates the Jenkinsfile. Once
    # it does, plain /build 400s; fall back to /buildWithParameters.
    local crumb http_code
    crumb=$(get_crumb)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "${ADMIN_USER}:${ADMIN_PASS}" -c "${WORKDIR}/cookies" -b "${WORKDIR}/cookies" -H "$crumb" \
        -X POST "${JENKINS_URL}/job/${job_name}/build")
    if [[ "$http_code" == "400" ]]; then
        echo "  (plain /build rejected — job already parameterized from a prior build; retrying with /buildWithParameters)"
        crumb=$(get_crumb)
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "${ADMIN_USER}:${ADMIN_PASS}" -c "${WORKDIR}/cookies" -b "${WORKDIR}/cookies" -H "$crumb" \
            -X POST "${JENKINS_URL}/job/${job_name}/buildWithParameters")
    fi
    if [[ "$http_code" != "201" ]]; then
        echo "✗ Failed to trigger ${job_name} — HTTP ${http_code}"
        exit 1
    fi
    echo "→ Waiting for the first build of ${job_name} to register the trigger..."
    REGISTER_BUILD="$before_register"
    for _ in $(seq 1 30); do
        sleep 5
        REGISTER_BUILD=$(current_build_number "$job_name")
        [[ "$REGISTER_BUILD" != "$before_register" ]] && break
    done
    if [[ "$REGISTER_BUILD" == "$before_register" ]]; then
        echo "✗ First build of ${job_name} never ran — trigger registration failed"
        exit 1
    fi
    echo "→ Trigger registered (${job_name} build #${REGISTER_BUILD})"

    # This build fails at Approval by design (no Gerrit uploader) — wait
    # for it, so the triggers{} block is loaded before any Gerrit push.
    wait_for_build_finish "$job_name" "$REGISTER_BUILD"
}

# Polls job_name's lastBuild/buildNumber every 5s, up to $iterations times,
# until it differs from $before. Sets NUM. Returns non-zero if it never
# changed.
_poll_build_number_until_changed() {
    local job_name="$1" before="$2" iterations="$3"
    NUM="$before"
    local i
    for ((i = 1; i <= iterations; i++)); do
        sleep 5
        NUM=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${job_name}/lastBuild/buildNumber" 2>/dev/null || echo "$before")
        if [[ "$NUM" != "$before" ]]; then
            echo "  (build number changed: #${before} → #${NUM}, after ${i} poll(s))"
            return 0
        fi
        [[ $((i % 6)) -eq 0 ]] && echo "  (still waiting — ${i}x5s elapsed, lastBuild still #${before})"
    done
    echo "  (gave up after ${iterations}x5s — lastBuild never changed from #${before})"
    return 1
}

# Blocks until job_name's lastBuild reaches before+count — used after a
# batch push (scripts/gerrit_multi_user_push.sh) where several triggers
# land close together, before we try to work out which build is whose.
wait_for_new_builds() {
    local job_name="$1" before="$2" count="$3"
    local target=$((before + count))
    echo "→ Waiting for ${count} new build(s) of ${job_name} (currently #${before})..."
    local i current
    for ((i = 1; i <= 60; i++)); do
        current=$(current_build_number "$job_name")
        if [[ "$current" -ge "$target" ]]; then
            echo "  (all ${count} present — lastBuild #${current})"
            return 0
        fi
        sleep 5
    done
    echo "✗ Only reached #${current} of the expected #${target} — a trigger may have failed"
    exit 1
}

# Maps each new build (before+1..before+count) to its owner, by grepping
# console log for the Approval stage's own line ("waiting for X to approve").
# Sets BUILD_OWNED_BY[username]=build_number (caller declares -A it first).
map_builds_to_owners() {
    local job_name="$1" before="$2" count="$3"; shift 3
    local usernames=("$@")
    local n
    for ((n = before + 1; n <= before + count; n++)); do
        local owner="" candidate console
        for _ in $(seq 1 30); do
            console=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${job_name}/${n}/consoleText" 2>/dev/null || echo "")
            for candidate in "${usernames[@]}"; do
                [[ "$console" == *"waiting for ${candidate} to approve this build."* ]] && { owner="$candidate"; break; }
            done
            [[ -n "$owner" ]] && break
            sleep 5
        done
        [[ -n "$owner" ]] || { echo "✗ Could not identify the owner of ${job_name} build #${n}"; exit 1; }
        BUILD_OWNED_BY["$owner"]="$n"
        echo "  (build #${n} → ${owner})"
    done
}

# Polls until job_name's build_number finishes (no longer "building").
# Doesn't treat a timeout as fatal — caller checks the actual result
# separately (report_build_result / check_build_ran_on).
wait_for_build_finish() {
    local job_name="$1" build_number="$2"
    echo "  (waiting for build #${build_number} to finish...)"
    for _ in $(seq 1 60); do
        local building
        building=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${job_name}/${build_number}/api/json" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['building'])")
        if [[ "$building" == "False" ]]; then
            echo "  (build #${build_number} finished)"
            return 0
        fi
        sleep 5
    done
    echo "  (build #${build_number} still building after 5 minutes — giving up waiting, but not treating this as a hard failure)"
    return 0
}

# Polls until job_name build_number has a pending `input` step waiting
# (the Approval stage's pause). Sets INPUT_ID from the pending action's id.
# Returns non-zero if it never appears within 5 minutes.
wait_for_pending_input() {
    local job_name="$1" build_number="$2"
    echo "→ Waiting for ${job_name} build #${build_number} to pause for approval..."
    sleep 1
    local resp_file http_code
    resp_file="$(mktemp -p "$WORKDIR")"
    for _ in $(seq 1 60); do
        # -o/-w instead of the old -sf: a silently-swallowed non-200 here
        # (permission quirk, plugin-version mismatch) looked identical to
        # "never paused" and left no evidence to tell them apart.
        http_code=$(curl -s -o "${resp_file}" -w '%{http_code}' -u "${ADMIN_USER}:${ADMIN_PASS}" \
            "${JENKINS_URL}/job/${job_name}/${build_number}/wfapi/pendingInputActions")
        if [[ "${http_code}" == "200" ]]; then
            INPUT_ID=$(python3 -c "import sys,json; a=json.load(sys.stdin); print(a[0]['id'] if a else '')" \
                < "${resp_file}" 2>/dev/null)
            if [[ -n "$INPUT_ID" ]]; then
                echo "  (paused, input id: ${INPUT_ID})"
                rm -f "${resp_file}"
                return 0
            fi
        fi
        sleep 5
    done

    echo "✗ ${job_name} build #${build_number} never paused for approval"
    echo "  (last wfapi call: HTTP ${http_code}, body: $(cat "${resp_file}" 2>/dev/null))"
    rm -f "${resp_file}"

    # Distinguish the two failure modes that look identical from the
    # outside: the Jenkinsfile echoes this line right before calling
    # input(), independently of wfapi. If it's in the console but wfapi
    # never reported a pending input, the pipeline DID pause and only the
    # REST endpoint is broken (plugin/version mismatch) — a very different
    # fix than the pipeline itself never reaching Approval.
    local console
    console=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
        "${JENKINS_URL}/job/${job_name}/${build_number}/consoleText" 2>/dev/null || echo "")
    if [[ "$console" == *"to approve this build."* ]]; then
        echo "  (console shows the pipeline DID pause — /wfapi/pendingInputActions itself is broken, not the pipeline)"
    else
        echo "  (console does NOT show the pause line — the pipeline itself never reached Approval, or errored first)"
    fi
    echo "──────────────────────────────────────────────────────────"
    echo "${console}"
    echo "──────────────────────────────────────────────────────────"
    return 1
}

# Confirms job_name/build_number's Approval stage actually proceeded — no
# pending input remains. submit_input_as returning HTTP 200 only means
# Jenkins accepted the click, not that it was the right identity.
confirm_input_cleared() {
    local job_name="$1" build_number="$2"
    for _ in $(seq 1 12); do
        local count
        count=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
            "${JENKINS_URL}/job/${job_name}/${build_number}/wfapi/pendingInputActions" \
            | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
        [[ "$count" == "0" ]] && return 0
        sleep 5
    done
    return 1
}

# Submits job_name/build_number's pending input_id, authenticated as
# username/password. HTTP 200 just means Jenkins accepted the click — the
# Jenkinsfile itself, not this HTTP call, is what verifies the identity.
submit_input_as() {
    local job_name="$1" build_number="$2" input_id="$3" username="$4" password="$5"
    local cookie_jar crumb
    cookie_jar=$(mktemp -p "$WORKDIR")
    crumb=$(curl -sf -u "${username}:${password}" -c "$cookie_jar" -b "$cookie_jar" \
        "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])" 2>/dev/null)
    SUBMIT_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "${username}:${password}" -c "$cookie_jar" -b "$cookie_jar" -H "$crumb" \
        -X POST "${JENKINS_URL}/job/${job_name}/${build_number}/input/${input_id}/proceedEmpty")
    rm -f "$cookie_jar"
    [[ "$SUBMIT_HTTP_CODE" == "200" ]]
}

# Confirms build_number of job_name actually ran on expected_node — this IS
# the routing check, since the shared job routes by dynamic agent label:
# whichever node's label matched the patchset owner is recorded here.
check_build_ran_on() {
    local job_name="$1" build_number="$2" expected_node="$3"
    echo "→ Checking which node ${job_name} build #${build_number} actually ran on..."
    local built_on
    # builtOn stays blank for Pipeline builds (not tracked at the Run
    # level) — the Dummy stage writes its node name into the build
    # description instead, so read that structured field here.
    built_on=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
        "${JENKINS_URL}/job/${job_name}/${build_number}/api/json" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('description') or '')")
    echo "  (builtOn: '${built_on}', expected: '${expected_node}')"
    if [[ "$built_on" != "$expected_node" ]]; then
        echo "✗ ${job_name} build #${build_number} ran on '${built_on}', expected '${expected_node}'"
        return 1
    fi
    echo "→ ${job_name} build #${build_number} correctly ran on '${expected_node}'"
    return 0
}

# Pushes a real, fresh patchset onto an existing Gerrit change over SSH.
# Clones fresh and pushes with a fixed Change-Id via a raw `git push` —
# same technique as scripts/gerrit_multi_user_push.sh.
push_real_gerrit_patchset() {
    local job_name="$1" gerrit_user="$2" gerrit_key_file="$3" gerrit_email="$4" \
          gerrit_display_name="$5" change_id="$6" before="$7"
    echo "→ Pushing a fresh patchset onto swiftacular (Change-Id ${change_id}) as ${gerrit_user}..."
    local gerrit_remote="ssh://${gerrit_user}@review.gerrithub.io:29418/davidsaOpenu/swiftacular"
    # IdentitiesOnly=yes is required: without it ssh also offers whatever's
    # in ssh-agent first, which can silently push as the WRONG GerritHub
    # account (Gerrit identifies by which key authenticated, not the URL).
    export GIT_SSH_COMMAND="ssh -i ${gerrit_key_file} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -p 29418"

    local clone_dir
    clone_dir=$(mktemp -d -p "$WORKDIR")
    echo "  → cloning into ${clone_dir}..."
    git clone -q "$gerrit_remote" "$clone_dir"

    # Installs Gerrit's commit-msg hook via one explicit scp, carrying -i
    # directly. -O forces the legacy SCP protocol — OpenSSH 9.0+ defaults to
    # SFTP, which Gerrit's SSH daemon (exec-only) rejects outright.
    local hook_file
    hook_file="$(git -C "$clone_dir" rev-parse --git-dir)/hooks/commit-msg"
    mkdir -p "$(dirname "$hook_file")"
    scp -O -i "$gerrit_key_file" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -P 29418 \
        "${gerrit_user}@review.gerrithub.io:hooks/commit-msg" "$hook_file"
    chmod +x "$hook_file"

    git -C "$clone_dir" config user.email "$gerrit_email"
    git -C "$clone_dir" config user.name "$gerrit_display_name"

    # A real (trivial) file change, not an empty commit. Under dr_test/ so
    # only jenkins-dr-test triggers, never the real swiftacular project job
    # (see commit 384345a — this push path had never inherited that fix).
    mkdir -p "$clone_dir/dr_test"
    echo "CI verification touch: $(date -u +%FT%TZ)" >> "$clone_dir/dr_test/.gerrit-trigger-check"
    git -C "$clone_dir" add -A

    # The hook only ADDS a Change-Id if the message doesn't already have
    # one — embedding the fixed one directly here is what correlates this
    # push to the existing change, no fetch-then-amend round trip needed.
    git -C "$clone_dir" commit -q -m "CI verification touch

Change-Id: ${change_id}"

    echo "  → pushing..."
    git -C "$clone_dir" push -q origin "HEAD:refs/for/master"
    echo "  → push complete"
    unset GIT_SSH_COMMAND

    echo "→ Waiting for ${job_name} to trigger..."
    if ! _poll_build_number_until_changed "$job_name" "$before" 60; then
        echo "✗ Trigger never resulted in a new build"
        exit 1
    fi
    # Breathing room: the build can reach its Approval pause in under a
    # second, and log lines emitted that fast get dropped by Jenkins' log
    # capture.
    sleep 2
}

# The VM is torn down right after the caller exits, taking the build's
# console log with it — dump it here first, or a failure is undiagnosable.
report_build_result() {
    local job_name="$1" build_number="$2"
    local result
    result=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/job/${job_name}/${build_number}/api/json" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")
    echo "→ ${job_name} build #${build_number} result: ${result}"

    # Always shown, not just on failure — real proof the job actually ran
    # and what it printed, straight from Jenkins' own build record. No
    # agent-side instrumentation needed for this visibility.
    echo "──────────────────────────────────────────────────────────"
    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
        "${JENKINS_URL}/job/${job_name}/${build_number}/consoleText" \
        || echo "(could not fetch console log)"
    echo "──────────────────────────────────────────────────────────"

    if [[ "$result" != "SUCCESS" ]]; then
        echo "✗ ${job_name} did not succeed"
        exit 1
    fi
}

print_final_status() {
    local mode_label="$1"
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo " Done"
    echo "════════════════════════════════════════════════════════════"
    echo "$mode_label"
    echo "  URL: ${JENKINS_URL}  user: ${ADMIN_USER}"
}

# Reads gerrit_central.yml's shape. Fails loudly if any mandatory field is
# blank, or if the SSH key / TLS files it names aren't on disk. No separate admin
# account — central's Gerrit identity IS the admin login (sets both).
load_central_account() {
    local path="$1"
    local output
    output=$(python3 - "$path" <<'PYEOF'
import os, re, sys, yaml
path = sys.argv[1]
d = yaml.safe_load(open(path)) or {}
# Only what the Gerrit Trigger plugin needs is mandatory: the account and
# its SSH key. Everything else is optional.
required = ['gerrit_username', 'ssh_key_name']
missing = [f for f in required if not d.get(f)]
if missing:
    print(f"✗ {path}: missing/blank required field(s): {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
# The end-to-end push test needs all three (CI sets them) — or none.
push = ('email', 'display_name', 'change_id')
if any(d.get(f) for f in push) and not all(d.get(f) for f in push):
    print(f"✗ {path}: set all of {', '.join(push)} (for the end-to-end push test), or leave all blank", file=sys.stderr)
    sys.exit(1)
# TLS: both set (a real certificate) or both blank (deploy_central_jenkins.sh
# makes a self-signed one) — never just one.
tls = ('tls_cert_file', 'tls_key_file')
if bool(d.get(tls[0])) != bool(d.get(tls[1])):
    print(f"✗ {path}: set both tls_cert_file and tls_key_file, or leave both blank", file=sys.stderr)
    sys.exit(1)
for f in tls:
    if d.get(f) and not os.path.isfile(d[f]):
        print(f"✗ {path}: {f} names {d[f]}, which is not a file on this machine", file=sys.stderr)
        sys.exit(1)
if 'jenkins_public_ip' in d:
    print(f"✗ {path}: jenkins_public_ip was replaced by jenkins_url (e.g. https://{d['jenkins_public_ip'] or '<ip>'}) — rename it", file=sys.stderr)
    sys.exit(1)
# jenkins_url: scheme://host[:port][/path], no query — the port is what
# nginx listens on (default 443/80), the path becomes Jenkins' --prefix.
# Normalized without trailing /.
url = (d.get('jenkins_url') or '').strip().rstrip('/')
if url:
    from urllib.parse import urlsplit
    u = urlsplit(url)
    try:
        port_ok = u.port is None or 1 <= u.port <= 65535
    except ValueError:
        port_ok = False
    if (u.scheme not in ('http', 'https') or not u.hostname or not port_ok
            or u.query or u.fragment or u.username
            or not re.fullmatch(r'(/[A-Za-z0-9._-]+)*', u.path)):
        print(f"✗ {path}: jenkins_url must look like https://host[:port][/path], e.g. https://192.114.0.189:9090/jenkins, got {url}", file=sys.stderr)
        sys.exit(1)
    if u.scheme == 'http' and d.get('tls_cert_file'):
        print(f"✗ {path}: tls_cert_file/tls_key_file are set but jenkins_url is http:// — use https:// or drop them", file=sys.stderr)
        sys.exit(1)
# Jenkins' own port, on 127.0.0.1 behind nginx — only ever needs changing
# when something else on the machine already holds the default 8080.
if 'jenkins_http_port' in d:
    print(f"✗ {path}: jenkins_http_port was renamed to jenkins_internal_port — rename it", file=sys.stderr)
    sys.exit(1)
internal_port = d.get('jenkins_internal_port') or ''
if internal_port != '':
    if not re.fullmatch(r'[0-9]{1,5}', str(internal_port)) or not 1 <= int(internal_port) <= 65535:
        print(f"✗ {path}: jenkins_internal_port must be a port number, got {internal_port}", file=sys.stderr)
        sys.exit(1)
print(f'CENTRAL_JENKINS_ADMIN_PASSWORD\t{d.get("jenkins_admin_password") or ""}')
print(f'CENTRAL_GERRIT_USERNAME\t{d["gerrit_username"]}')
print(f'CENTRAL_SSH_KEY_NAME\t{d["ssh_key_name"]}')
print(f'CENTRAL_GERRIT_EMAIL\t{d.get("email") or ""}')
print(f'CENTRAL_GERRIT_DISPLAY_NAME\t{d.get("display_name") or ""}')
print(f'CENTRAL_CHANGE_ID\t{d.get("change_id") or ""}')
print(f'CENTRAL_JENKINS_URL\t{url}')
shared = d.get('nginx_shared_server', False)
if shared in (None, ''):
    shared = False
if not isinstance(shared, bool):
    print(f"✗ {path}: nginx_shared_server must be true or false, got {shared!r}", file=sys.stderr)
    sys.exit(1)
print(f'CENTRAL_JENKINS_INTERNAL_PORT\t{internal_port}')
print(f'CENTRAL_NGINX_SHARED_SERVER\t{"true" if shared else "false"}')
print(f'CENTRAL_TLS_CERT_FILE\t{d.get("tls_cert_file") or ""}')
print(f'CENTRAL_TLS_KEY_FILE\t{d.get("tls_key_file") or ""}')
PYEOF
    ) || exit 1
    while IFS=$'\t' read -r key value; do
        printf -v "$key" '%s' "$value"
    done <<< "$output"
    CENTRAL_JENKINS_ADMIN_USER="$CENTRAL_GERRIT_USERNAME"
    CENTRAL_VERIFY_PUSH=false
    [[ -n "$CENTRAL_CHANGE_ID" ]] && CENTRAL_VERIFY_PUSH=true

    CENTRAL_GERRIT_KEY_FILE="${HOME}/.ssh/${CENTRAL_SSH_KEY_NAME}"
    [[ -f "$CENTRAL_GERRIT_KEY_FILE" ]] \
        || { echo "✗ ${CENTRAL_GERRIT_KEY_FILE} not found — place the private key registered as ssh_key_name there first"; exit 1; }
}

# Loads all 3 identities from scripts/gerrit_users.sh's USERS array — index
# 0 is central, 1/2 are node A/B. Also derives CENTRAL_JENKINS_ADMIN_USER/
# PASSWORD (<gerrit_username>/<gerrit_username>1234 — the throwaway test VM's own fresh Jenkins login, not a real system).
load_gerrit_users() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${script_dir}/scripts/gerrit_users.sh"

    # Central still resolves a real key-file path (CENTRAL_GERRIT_KEY_FILE)
    # — register_central_key.sh (run.sh's Step 4b) writes it there before
    # deploy_central's scp reads it, so no existence check here: the file
    # doesn't exist yet at load_gerrit_users() time. Node A/B have no
    # static key file at all — /opt/ci/gerrit_multi_user_push.sh handles
    # their SSH keys itself, ephemeral and per-push.
    local prefixes=(CENTRAL NODE_A NODE_B)
    local i entry username key_name email display_name change_id
    for i in 0 1 2; do
        entry="${USERS[$i]}"
        IFS='|' read -r username key_name email display_name change_id <<< "$entry"
        local prefix="${prefixes[$i]}"
        printf -v "${prefix}_GERRIT_USERNAME" '%s' "$username"
        printf -v "${prefix}_SSH_KEY_NAME" '%s' "$key_name"
        printf -v "${prefix}_GERRIT_EMAIL" '%s' "$email"
        printf -v "${prefix}_GERRIT_DISPLAY_NAME" '%s' "$display_name"
        printf -v "${prefix}_CHANGE_ID" '%s' "$change_id"
    done
    CENTRAL_GERRIT_KEY_FILE="${HOME}/.ssh/${CENTRAL_SSH_KEY_NAME}"

    # No separate admin account — central's Gerrit identity IS the admin
    # login (jenkins.yaml.j2 creates only the one user).
    CENTRAL_JENKINS_ADMIN_USER="$CENTRAL_GERRIT_USERNAME"
    CENTRAL_JENKINS_ADMIN_PASSWORD="${CENTRAL_GERRIT_USERNAME}1234"
}

# Confirms key_file parses as a real private key — catches a placeholder
# or a corrupted PEM before anything ever touches the network.
_is_valid_private_key() {
    local key_file="$1"
    ssh-keygen -y -f "$key_file" >/dev/null 2>&1
}

# Confirms key_file authenticates to GerritHub AS username specifically —
# Gerrit binds the connecting identity to the key, so this proves both
# "the key works" and "it's the right account" in one round trip.
_gerrit_ssh_identity_ok() {
    local key_file="$1" username="$2"
    ssh -i "$key_file" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
        -o BatchMode=yes -o ConnectTimeout=10 \
        -p 29418 "${username}@review.gerrithub.io" gerrit version >/dev/null 2>&1
}

# Confirms change_id is a real, reachable Gerrit change. Queries by search
# (not GET /changes/<id>) since a Change-Id isn't guaranteed globally
# unique — a non-empty result list is enough to confirm it resolves.
_gerrit_change_reachable() {
    local change_id="$1"
    [[ -z "$change_id" ]] && return 0
    curl -sf --connect-timeout 10 "https://review.gerrithub.io/changes/?q=change:${change_id}" \
        | tail -c +5 | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin) else 1)" 2>/dev/null
}

# Preflight for one Gerrit identity — call before any VM is spawned, so a
# bad credential fails in seconds instead of ~20 minutes into a real run.
validate_gerrit_account() {
    local label="$1" key_file="$2" username="$3" change_id="$4"
    echo "→ Validating Gerrit credentials for ${label} (${username})..."

    _is_valid_private_key "$key_file" \
        || { echo "✗ ${label}: ${key_file} is not a valid private key (missing, placeholder text left in, or corrupted)"; exit 1; }

    _gerrit_ssh_identity_ok "$key_file" "$username" \
        || { echo "✗ ${label}: SSH auth as '${username}' failed — key not registered to this GerritHub account, or username is wrong"; exit 1; }

    _gerrit_change_reachable "$change_id" \
        || { echo "✗ ${label}: Gerrit change ${change_id} is not reachable — check change_id"; exit 1; }

    echo "  ✓ ${label} credentials valid"
}

# Same derivation as agentLabel() (Jenkinsfile), labelString (jenkins.yaml.j2),
# and create_agent_node() (setup_students.sh) — a mismatch here means
# nothing ever routes there.
sanitize_label() {
    echo -n "$1" | sed -E 's/[^A-Za-z0-9]+/-/g'
}
