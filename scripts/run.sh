#!/usr/bin/env bash
# Test harness: proves the deploy scripts work in disposable VMs (left
# running afterward — cleanup.sh tears down). Usage: ./run.sh [--local-repo]
# Step implementations live in run_common.sh / deploy_verify.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/run_common.sh"
source "${SCRIPT_DIR}/deploy_verify.sh"

main() {
    parse_args "$@"
    common_setup "$@"

    # TEST ONLY — checking whether the jenkins user can read the same
    # secrets /opt/ci/gerrit_multi_user_push.sh uses, to see if Steps 3/5
    # could reuse its ephemeral-key approach instead of static ~/.ssh files.
    # Non-fatal either way; safe to remove once we know the answer.
    TOKENS_FILE="/opt/ci/secrets/gerrit_tokens.env"
    if [[ -r "$TOKENS_FILE" ]]; then
        echo "✓ can read ${TOKENS_FILE} as $(id -un)"
        set -a; source "$TOKENS_FILE"; set +a
        for v in JENKINS_OSW_TOKEN JENKINS_USERA_TOKEN JENKINS_USERB_TOKEN; do
            [[ -n "${!v:-}" ]] && echo "  ${v} is set" || echo "  ${v} is NOT set"
        done
    else
        echo "✗ cannot read ${TOKENS_FILE} as $(id -un) (expected if root:root 600)"
    fi

    # Step 1: tear down any VMs left over from a previous run, so every run
    # starts from a genuinely clean, consistent state
    clean_start

    # Step 2: optionally serve this checkout over a local git daemon
    [[ "$LOCAL_REPO" == "true" ]] && start_local_git_daemon

    # Step 3: load all 3 Gerrit identities, then confirm each is usable
    # before any VM is spawned — a bad credential fails in seconds, not
    # ~20 minutes in.
    load_gerrit_users
    ADMIN_USER="$CENTRAL_JENKINS_ADMIN_USER"
    ADMIN_PASS="$CENTRAL_JENKINS_ADMIN_PASSWORD"

    validate_gerrit_account "central" "$CENTRAL_GERRIT_KEY_FILE" "$CENTRAL_GERRIT_USERNAME" "$CENTRAL_CHANGE_ID"
    validate_gerrit_account "node-a" "$NODE_A_KEY_FILE" "$NODE_A_GERRIT_USERNAME" "$NODE_A_CHANGE_ID"
    validate_gerrit_account "node-b" "$NODE_B_KEY_FILE" "$NODE_B_GERRIT_USERNAME" "$NODE_B_CHANGE_ID"

    # Step 4: spawn the VMs — all 3 up, same as a full run
    ensure_java_box
    spawn_vm "jenkins-01" "$CENTRAL_VAGRANTFILE"
    spawn_vm "node-a" "$STUDENT_VAGRANTFILE"
    spawn_vm "node-b" "$STUDENT_VAGRANTFILE"
    build_ssh_cfg "jenkins-01" "$CENTRAL_VAGRANTFILE"
    build_ssh_cfg "node-a" "$STUDENT_VAGRANTFILE"
    build_ssh_cfg "node-b" "$STUDENT_VAGRANTFILE"

    # Step 5: deploy central Jenkins inside its VM
    build_central_vm_secrets
    deploy_central "jenkins-01" "$CENTRAL_VM_SECRETS"

    # Step 6: provision node-a and node-b as real students via
    # setup_students.sh. Sets NODEA_NAME/NODEA_SECRET, NODEB_NAME/NODEB_SECRET.
    provision_test_students

    build_node_secrets "${WORKDIR}/node_a_secrets.yml" "$NODE_A_GERRIT_USERNAME" "$NODEA_NAME" "$NODEA_SECRET"
    build_node_secrets "${WORKDIR}/node_b_secrets.yml" "$NODE_B_GERRIT_USERNAME" "$NODEB_NAME" "$NODEB_SECRET"
    deploy_agent "node-a" "${WORKDIR}/node_a_secrets.yml"
    deploy_agent "node-b" "${WORKDIR}/node_b_secrets.yml"
    wait_for_agent_online "$NODEA_NAME" 24
    wait_for_agent_online "$NODEB_NAME" 24

    # Matches the literal jobs/swiftacular-dummy/Jenkinsfile's Dummy stage
    # normalizes env.NODE_NAME (blank on the built-in node) to.
    CENTRAL_NAME="built-in"

    # Step 7: register the trigger once — it only needs one build ever to
    # be picked up, not one per event.
    register_gerrit_trigger "$DUMMY_JOB"

    # Step 8: push all 3 identities as a batch, exactly like a real
    # multi-student push wave — the root-installed gerrit_multi_user_push.sh
    # does the pushing itself (ephemeral keys, per-user token), same as
    # jobs/jenkins/Jenkinsfile's own daily run.sh invokes it.
    title "Pushing all 3 identities (central, node-a, node-b)..."
    PUSH_BEFORE=$(current_build_number "$DUMMY_JOB")
    sudo /opt/ci/gerrit_multi_user_push.sh

    # Step 9: wait for all 3 triggers to land, then work out which build
    # belongs to which pusher (their arrival order isn't guaranteed).
    wait_for_new_builds "$DUMMY_JOB" "$PUSH_BEFORE" 3
    declare -A BUILD_OWNED_BY
    map_builds_to_owners "$DUMMY_JOB" "$PUSH_BEFORE" 3 \
        "$CENTRAL_GERRIT_USERNAME" "$NODE_A_GERRIT_USERNAME" "$NODE_B_GERRIT_USERNAME"

    # Step 10: central approves as its own Gerrit-identity account (JCasC-
    # created, same password as admin) — no distinct non-admin account to
    # cross-test against, so it skips the wrong_user/wrong_pass args.
    title "Central build — expect it built on the built-in node (${CENTRAL_NAME}); node-a and node-b should never be candidates"
    verify_node_routing "$CENTRAL_NAME" "${BUILD_OWNED_BY[$CENTRAL_GERRIT_USERNAME]}" "$CENTRAL_GERRIT_USERNAME" "$ADMIN_PASS"

    # Node A/B cross-test each other: node B must NOT be able to approve
    # node A's build (and vice versa) before the real submitter approves it.
    title "Node A build — expect it built on ${NODEA_NAME}; node-b and the built-in node should never be candidates"
    verify_node_routing "$NODEA_NAME" "${BUILD_OWNED_BY[$NODE_A_GERRIT_USERNAME]}" \
        "$NODE_A_GERRIT_USERNAME" "$STUDENT_TEST_PASSWORD" "$NODE_B_GERRIT_USERNAME" "$STUDENT_TEST_PASSWORD"

    title "Node B build — expect it built on ${NODEB_NAME}; node-a and the built-in node should never be candidates"
    verify_node_routing "$NODEB_NAME" "${BUILD_OWNED_BY[$NODE_B_GERRIT_USERNAME]}" \
        "$NODE_B_GERRIT_USERNAME" "$STUDENT_TEST_PASSWORD" "$NODE_A_GERRIT_USERNAME" "$STUDENT_TEST_PASSWORD"

    print_final_status "✓ Central + both agents deployed and online; all 3 identities pushed together, routing verified."
}

main "$@"
