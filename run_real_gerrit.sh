#!/usr/bin/env bash
# Manual production deploy: builds a fresh Jenkins the same way run.sh does,
# but reads central_deploy/roles/jenkins/vars/vault.yml (ansible-vault
# encrypted) for the real admin password and a real GerritHub-registered SSH
# key, connects to GerritHub for real, and optionally pushes a real patchset
# (see vault_dummy_change_number below) to prove the trigger end-to-end. For
# an instructor manually standing up a real replacement — cron/Gerrit-
# triggered runs use run.sh instead.
#
# Non-interactive: export VAULT_PASSWORD_FILE=/path/to/vault_pass
# Interactive: just run it, you'll be prompted once.
#
# vault_dummy_change_number (in vault.yml) controls how Step 7 verifies:
#   - set to a permanent Gerrit change reserved on davidsaOpenu/swiftacular:
#     pushes a fresh, real patchset onto it to exercise the actual Gerrit
#     trigger wiring end-to-end. (Not a comment — gerrit-trigger silently
#     skips comments authored by its own configured user to avoid feedback
#     loops from its own Verified votes; a new patchset has no such
#     restriction, same as running `git review`.)
#   - left blank: injects a simulated patchset-created event directly into
#     gerrit-trigger's own processing pipeline instead — no dummy change
#     needed, zero network calls to GerritHub.
#
# The VM is always left running after this script exits, success or failure —
# ready to serve as the central Jenkins immediately, or to SSH in and debug.
# Use cleanup.sh separately to tear it down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/run_common.sh"

load_real_gerrit_credentials() {
    if [[ -n "${VAULT_PASSWORD_FILE:-}" ]]; then
        cp "$VAULT_PASSWORD_FILE" "$TMP_VAULT_PASS"
    else
        local vault_pass
        read -rsp "Ansible Vault password: " vault_pass
        echo
        printf '%s' "$vault_pass" > "$TMP_VAULT_PASS"
    fi
    VAULT_ARGS+=(--vault-password-file="$TMP_VAULT_PASS")
    EXTRA_VARS+=(-e "vault_in_use=true" -e "gerrit_connect_on_startup=true")

    local vault_data
    vault_data=$(ansible-vault view "$VAULT_FILE" --vault-password-file="$TMP_VAULT_PASS")
    ADMIN_PASS=$(echo "$vault_data" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['vault_jenkins_admin_password'])")
    GERRIT_USER=$(echo "$vault_data" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['vault_gerrit_ssh_username'])")
    GERRIT_EMAIL=$(echo "$vault_data" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('vault_gerrit_email') or '')")
    DUMMY_CHANGE_NUMBER=$(echo "$vault_data" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('vault_dummy_change_number') or '')")
    echo "$vault_data" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['vault_gerrit_ssh_private_key'], end='')" > "$TMP_GERRIT_KEY"
}

validate_dummy_change_number() {
    if [[ -n "$DUMMY_CHANGE_NUMBER" && ! "$DUMMY_CHANGE_NUMBER" =~ ^[0-9]+$ ]]; then
        echo "✗ vault_dummy_change_number must be numeric, got: ${DUMMY_CHANGE_NUMBER}"
        exit 1
    fi
    # Only the real-push path needs a registered email — the simulated-event
    # path (blank vault_dummy_change_number) never touches GerritHub at all.
    if [[ -n "$DUMMY_CHANGE_NUMBER" && -z "$GERRIT_EMAIL" ]]; then
        echo "✗ vault_dummy_change_number is set but vault_gerrit_email is blank — required to push the verification patchset"
        exit 1
    fi
}

push_real_gerrit_patchset() {
    local before="$1"
    echo "→ Pushing a fresh patchset onto swiftacular change ${DUMMY_CHANGE_NUMBER}..."
    local ref_prefix gerrit_remote
    ref_prefix=$(printf '%02d' $((DUMMY_CHANGE_NUMBER % 100)))
    gerrit_remote="ssh://${GERRIT_USER}@review.gerrithub.io:29418/davidsaOpenu/swiftacular"
    export GIT_SSH_COMMAND="ssh -i ${TMP_GERRIT_KEY} -o StrictHostKeyChecking=no -p 29418"

    # git fetch needs an exact ref, not a bare wildcard — resolve the current
    # highest patchset number for this change first via ls-remote.
    local latest_ref
    latest_ref=$(git ls-remote "$gerrit_remote" "refs/changes/${ref_prefix}/${DUMMY_CHANGE_NUMBER}/*" \
        | sort -t/ -k5 -n | tail -1 | awk '{print $2}')
    if [[ -z "$latest_ref" ]]; then
        echo "✗ Could not find any patchset ref for change ${DUMMY_CHANGE_NUMBER}"
        exit 1
    fi

    TMP_CLONE=$(mktemp -d)
    git -C "$TMP_CLONE" init -q
    git -C "$TMP_CLONE" remote add origin "$gerrit_remote"
    git -C "$TMP_CLONE" fetch -q origin "$latest_ref"
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
    if ! wait_for_new_build "$before"; then
        echo "✗ Trigger never resulted in a new build"
        exit 1
    fi
}

main() {
    common_setup "$@"
    diagnose_jenkins_reachability

    spawn_vm
    build_inventory

    title "Step 4/8 — Credentials"
    VAULT_ARGS=()
    EXTRA_VARS=()
    load_real_gerrit_credentials
    validate_dummy_change_number
    chmod 600 "$TMP_GERRIT_KEY"

    deploy_jenkins
    register_gerrit_trigger

    if [[ -z "$DUMMY_CHANGE_NUMBER" ]]; then
        title "Step 7/8 — Simulate Gerrit event directly (no GerritHub)"
        simulate_gerrit_event "$REGISTER_BUILD"
    else
        title "Step 7/8 — Trigger via REAL Gerrit event and wait"
        push_real_gerrit_patchset "$REGISTER_BUILD"
    fi

    report_build_result
    print_final_status "✓ Fresh Jenkins verified and ready to replace the central instance."
}

main "$@"
