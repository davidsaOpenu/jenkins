#!/usr/bin/env bash
# Shared Gerrit-trigger verification + credential-loading functions. Sourced
# only — not meant to be executed directly. Used by
# central_deploy/deploy_central_jenkins.sh and run.sh.
#
# Functions read/write shared globals the caller is expected to have set:
# JENKINS_URL, ADMIN_USER, ADMIN_PASS, WORKDIR (a caller-owned, trap-cleaned
# scratch directory). Only per-call values (job name, owner, build number)
# are passed as parameters.

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
    # has parameters until its first build evaluates the Jenkinsfile's own
    # parameters{} block. But once that's happened at least once (e.g. this
    # job already has prior builds from an earlier run), Jenkins now knows
    # it's parameterized and rejects plain /build with "400 Nothing is
    # submitted" — fall back to /buildWithParameters (using the
    # Jenkinsfile's own declared defaults, no values passed) in that case.
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

    # This registration build hits the same Approval gate as a real event —
    # it wasn't triggered by Gerrit, so GERRIT_CHANGE_OWNER_USERNAME (and
    # therefore submitter:) is null there, which leaves the input
    # unrestricted to any authenticated user. Approve it as admin so it
    # doesn't just sit on Approval for its own 15-minute timeout; best
    # effort only — its outcome was never checked before and still isn't.
    if wait_for_pending_input "$job_name" "$REGISTER_BUILD"; then
        submit_input_as "$job_name" "$REGISTER_BUILD" "$INPUT_ID" "$ADMIN_USER" "$ADMIN_PASS" \
            || echo "  (could not approve the registration build — continuing anyway, harmless)"
    fi
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
    for _ in $(seq 1 60); do
        INPUT_ID=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
            "${JENKINS_URL}/job/${job_name}/${build_number}/wfapi/pendingInputActions" \
            | python3 -c "import sys,json; a=json.load(sys.stdin); print(a[0]['id'] if a else '')" 2>/dev/null)
        if [[ -n "$INPUT_ID" ]]; then
            echo "  (paused, input id: ${INPUT_ID})"
            return 0
        fi
        sleep 5
    done
    echo "✗ ${job_name} build #${build_number} never paused for approval"
    return 1
}

# Confirms job_name/build_number's Approval stage actually proceeded — no
# pending input remains. submit_input_as returning HTTP 200 only means
# Jenkins accepted the click, not that it was the right identity (a wrong
# one still gets 200 but leaves a fresh pending input instead of clearing
# it) — this is the real confirmation the approval took effect.
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
# the routing check now that a single shared job (swiftacular-dummy) routes
# by dynamic agent label instead of one job per node: whichever node's label
# matched the patchset owner is authoritatively recorded there, no separate
# "did the other node stay silent" check needed.
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

# Pushes a real, fresh patchset onto an existing Gerrit change over SSH,
# exercising the actual gerrit-trigger SSH stream-events listener end-to-end.
# Not a comment — gerrit-trigger silently skips comments authored by its own
# configured user to avoid feedback loops from its own Verified votes; a
# fresh patchset has no such restriction, same as running `git review`.
push_real_gerrit_patchset() {
    local job_name="$1" gerrit_user="$2" gerrit_key_file="$3" gerrit_email="$4" change_number="$5" before="$6"
    echo "→ Pushing a fresh patchset onto swiftacular change ${change_number} as ${gerrit_user}..."
    local ref_prefix gerrit_remote
    ref_prefix=$(printf '%02d' $((change_number % 100)))
    gerrit_remote="ssh://${gerrit_user}@review.gerrithub.io:29418/davidsaOpenu/swiftacular"
    # IdentitiesOnly=yes is required, not optional: without it ssh also
    # offers whatever's loaded in ssh-agent, tried before -i's key — on a
    # machine with a personal key already agent-loaded, that key can
    # authenticate successfully first, silently pushing as the WRONG
    # GerritHub account (Gerrit identifies the account by which key
    # authenticated, not by the ssh:// URL's username).
    export GIT_SSH_COMMAND="ssh -i ${gerrit_key_file} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -p 29418"

    # git review's commit-msg-hook fetch shells out to a bare `scp`, which
    # GIT_SSH_COMMAND doesn't cover (scp resolves identity on its own) — on
    # a fresh VM with no agent/default key it fails outright. Shim `scp` on
    # PATH instead, git-review's only interception point for this.
    local scp_wrapper_dir
    scp_wrapper_dir=$(mktemp -d -p "$WORKDIR")
    cat > "${scp_wrapper_dir}/scp" <<EOF
#!/bin/bash
exec $(command -v scp) -i "${gerrit_key_file}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no "\$@"
EOF
    chmod +x "${scp_wrapper_dir}/scp"
    export PATH="${scp_wrapper_dir}:${PATH}"

    # git fetch needs an exact ref, not a bare wildcard — resolve the current
    # highest patchset number for this change first via ls-remote.
    echo "  → resolving latest patchset ref for change ${change_number}..."
    local latest_ref
    latest_ref=$(git ls-remote "$gerrit_remote" "refs/changes/${ref_prefix}/${change_number}/*" \
        | sort -t/ -k5 -n | tail -1 | awk '{print $2}')
    if [[ -z "$latest_ref" ]]; then
        echo "✗ Could not find any patchset ref for change ${change_number}"
        unset GIT_SSH_COMMAND
        exit 1
    fi
    echo "  → latest ref: ${latest_ref}"

    # Gerrit tracks a change by its Change-Id trailer, assigned server-side
    # regardless of whether the fetched commit carries one. Trusting --amend
    # --no-edit to preserve it risks opening a brand-new change instead of
    # updating this one — fetch the real Change-Id from Gerrit and force it
    # into the message instead.
    echo "  → resolving this change's real Change-Id..."
    local gerrit_change_id
    gerrit_change_id=$(curl -sf "https://review.gerrithub.io/changes/${change_number}" \
        | tail -c +5 | python3 -c "import sys,json; print(json.load(sys.stdin)['change_id'])")
    echo "  → Change-Id: ${gerrit_change_id}"

    local clone_dir
    clone_dir=$(mktemp -d -p "$WORKDIR")
    echo "  → cloning into ${clone_dir}..."
    git -C "$clone_dir" init -q
    git -C "$clone_dir" remote add origin "$gerrit_remote"
    git -C "$clone_dir" fetch -q origin "$latest_ref"
    git -C "$clone_dir" checkout -q FETCH_HEAD
    git -C "$clone_dir" config user.email "$gerrit_email"
    git -C "$clone_dir" config user.name "$gerrit_user"
    echo "  → fetched and checked out"
    # A real (trivial) file change, not an empty commit — mirrors an actual
    # `change file -> add -> commit -> git review` cycle.
    echo "CI verification touch: $(date -u +%FT%TZ)" >> "$clone_dir/.gerrit-trigger-check"
    git -C "$clone_dir" add -A

    # Rebuild the commit message with exactly one Change-Id trailer — the
    # real one from Gerrit — dropping any existing Change-Id line rather
    # than trusting it to already be correct.
    local msg_file="${WORKDIR}/commit_msg_${change_number}"
    git -C "$clone_dir" log -1 --format=%B | grep -v '^Change-Id:' > "$msg_file"
    printf '\nChange-Id: %s\n' "$gerrit_change_id" >> "$msg_file"
    git -C "$clone_dir" commit -q --amend -F "$msg_file"

    # Push via the real `git review` binary rather than a raw `git push
    # ...:refs/for/master` — exactly what was manually confirmed to fire the
    # trigger. -r origin points it at the remote already set up above
    # (named "origin", not git-review's usual default "gerrit"); -y skips
    # its interactive confirmation prompt for this non-interactive run.
    # gitreview.username is set locally (not --global) so git-review never
    # falls back to interpreting a bare positional arg as a branch name.
    echo "  → amended commit (Change-Id: ${gerrit_change_id}), pushing via git review..."
    git -C "$clone_dir" config gitreview.username "$gerrit_user"
    (cd "$clone_dir" && git review -y -r origin)
    echo "  → push complete"
    unset GIT_SSH_COMMAND
    export PATH="${PATH#"${scp_wrapper_dir}:"}"

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
# blank. Sets: CENTRAL_JENKINS_ADMIN_USER, CENTRAL_JENKINS_ADMIN_PASSWORD,
# CENTRAL_GERRIT_USERNAME, CENTRAL_GERRIT_EMAIL, CENTRAL_GERRIT_KEY_FILE
# (private key written to a WORKDIR-scoped file, mode 600),
# CENTRAL_DUMMY_CHANGE_NUMBER, CENTRAL_DUMMY_JOB_REPO_URL (optional, blank if
# unset).
load_central_account() {
    local path="$1"
    local output
    output=$(python3 - "$path" <<'PYEOF'
import sys, yaml
path = sys.argv[1]
d = yaml.safe_load(open(path)) or {}
required = ['jenkins_admin_user', 'jenkins_admin_password', 'gerrit_ssh_username',
            'gerrit_email', 'gerrit_ssh_private_key', 'dummy_change_number']
missing = [f for f in required if not d.get(f)]
if missing:
    print(f"✗ {path}: missing/blank required field(s): {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
print(f'CENTRAL_JENKINS_ADMIN_USER\t{d["jenkins_admin_user"]}')
print(f'CENTRAL_JENKINS_ADMIN_PASSWORD\t{d["jenkins_admin_password"]}')
print(f'CENTRAL_GERRIT_USERNAME\t{d["gerrit_ssh_username"]}')
print(f'CENTRAL_GERRIT_EMAIL\t{d["gerrit_email"]}')
print(f'CENTRAL_DUMMY_CHANGE_NUMBER\t{d["dummy_change_number"]}')
print(f'CENTRAL_DUMMY_JOB_REPO_URL\t{d.get("dummy_job_repo_url") or ""}')
PYEOF
    ) || exit 1
    while IFS=$'\t' read -r key value; do
        printf -v "$key" '%s' "$value"
    done <<< "$output"

    CENTRAL_GERRIT_KEY_FILE="${WORKDIR}/central_gerrit_key"
    python3 -c "import yaml,sys; sys.stdout.write(yaml.safe_load(open(sys.argv[1]))['gerrit_ssh_private_key'])" "$path" > "$CENTRAL_GERRIT_KEY_FILE"
    chmod 600 "$CENTRAL_GERRIT_KEY_FILE"
}

# Reads gerrit_agents.yml's shape. Fails loudly if either node's fields are
# blank — both node_a and node_b are mandatory, same as gerrit_central.yml.
# Sets NODE_A_GERRIT_USERNAME/NODE_A_GERRIT_EMAIL/NODE_A_KEY_FILE/
# NODE_A_DUMMY_CHANGE_NUMBER (and NODE_B_* the same way).
load_agent_accounts() {
    local path="$1"
    local output
    output=$(python3 - "$path" <<'PYEOF'
import sys, yaml
path = sys.argv[1]
d = yaml.safe_load(open(path)) or {}
# dummy_change_number temporarily not required — see run.sh Step 6 (commented out)
required = ['gerrit_ssh_username', 'gerrit_email', 'gerrit_ssh_private_key']
for prefix, key in (('NODE_A', 'node_a'), ('NODE_B', 'node_b')):
    node = d.get(key) or {}
    missing = [f for f in required if not node.get(f)]
    if missing:
        print(f"✗ {path}: {key} missing/blank required field(s): {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)
    print(f'{prefix}_GERRIT_USERNAME\t{node["gerrit_ssh_username"]}')
    print(f'{prefix}_GERRIT_EMAIL\t{node["gerrit_email"]}')
    print(f'{prefix}_DUMMY_CHANGE_NUMBER\t{node.get("dummy_change_number") or ""}')
PYEOF
    ) || exit 1
    while IFS=$'\t' read -r key value; do
        printf -v "$key" '%s' "$value"
    done <<< "$output"

    NODE_A_KEY_FILE="${WORKDIR}/node_a_gerrit_key"
    python3 -c "import yaml,sys; sys.stdout.write(yaml.safe_load(open(sys.argv[1]))['node_a']['gerrit_ssh_private_key'])" "$path" > "$NODE_A_KEY_FILE"
    chmod 600 "$NODE_A_KEY_FILE"

    NODE_B_KEY_FILE="${WORKDIR}/node_b_gerrit_key"
    python3 -c "import yaml,sys; sys.stdout.write(yaml.safe_load(open(sys.argv[1]))['node_b']['gerrit_ssh_private_key'])" "$path" > "$NODE_B_KEY_FILE"
    chmod 600 "$NODE_B_KEY_FILE"
}

# Confirms key_file parses as a real private key — catches a placeholder
# (e.g. "paste_your_private_key_here" left in from the .example file) or a
# YAML-corrupted PEM (bad indent, CRLF) before anything ever touches the
# network.
_is_valid_private_key() {
    local key_file="$1"
    ssh-keygen -y -f "$key_file" >/dev/null 2>&1
}

# Confirms key_file authenticates to GerritHub AS username specifically.
# Gerrit's SSH daemon binds the connecting username to whichever account the
# key belongs to, so one round trip here proves both "the key works" and
# "it's the right account" — not just "some key works for someone".
_gerrit_ssh_identity_ok() {
    local key_file="$1" username="$2"
    ssh -i "$key_file" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
        -o BatchMode=yes -o ConnectTimeout=10 \
        -p 29418 "${username}@review.gerrithub.io" gerrit version >/dev/null 2>&1
}

# Confirms change_number is a real, reachable Gerrit change — the one
# push_real_gerrit_patchset will target later. Blank passes: agent accounts'
# dummy_change_number is optional (see load_agent_accounts).
_gerrit_change_reachable() {
    local change_number="$1"
    [[ -z "$change_number" ]] && return 0
    curl -sf --connect-timeout 10 "https://review.gerrithub.io/changes/${change_number}" >/dev/null 2>&1
}

# Preflight for one Gerrit identity (central, node_a, node_b, ...) — call
# right after load_central_account/load_agent_accounts, before any VM is
# spawned. A bad credential then fails in seconds with an exact reason,
# instead of ~20 minutes in inside push_real_gerrit_patchset's own ssh/
# git-review call.
validate_gerrit_account() {
    local label="$1" key_file="$2" username="$3" change_number="$4"
    echo "→ Validating Gerrit credentials for ${label} (${username})..."

    _is_valid_private_key "$key_file" \
        || { echo "✗ ${label}: ${key_file} is not a valid private key (placeholder text left in, or corrupted)"; exit 1; }

    _gerrit_ssh_identity_ok "$key_file" "$username" \
        || { echo "✗ ${label}: SSH auth as '${username}' failed — key not registered to this GerritHub account, or username is wrong"; exit 1; }

    _gerrit_change_reachable "$change_number" \
        || { echo "✗ ${label}: Gerrit change ${change_number} is not reachable — check dummy_change_number"; exit 1; }

    echo "  ✓ ${label} credentials valid"
}

# Same derivation as jobs/swiftacular-dummy/Jenkinsfile's agentLabel(),
# jenkins.yaml.j2's built-in-node labelString, and setup_students.sh's
# create_agent_node() — must stay identical to all four, since a mismatch
# here would just mean nothing ever routes there.
sanitize_label() {
    echo -n "$1" | sed -E 's/[^A-Za-z0-9]+/-/g'
}
