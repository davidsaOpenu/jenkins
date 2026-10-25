#!/usr/bin/env bash
# Test harness: proves the deploy scripts work in disposable VMs (left
# running afterward — cleanup.sh tears down). Usage: ./run.sh
# Step implementations live in run_common.sh / deploy_verify.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/run_common.sh"
source "${SCRIPT_DIR}/deploy_verify.sh"

main() {
    parse_args "$@"
    common_setup "$@"

    # Step 1: tear down any VMs left over from a previous run, so every run
    # starts from a genuinely clean, consistent state
    clean_start

    # Step 3: load all 3 Gerrit identities. Central's key isn't a static
    # file to validate ahead of time anymore — register_central_key.sh
    # (Step 4b) generates and registers it fresh for this VM's lifetime.
    load_gerrit_users
    ADMIN_USER="$CENTRAL_JENKINS_ADMIN_USER"
    ADMIN_PASS="$CENTRAL_JENKINS_ADMIN_PASSWORD"

    # Step 4: spawn the VMs — all 3 up, same as a full run
    ensure_java_box
    spawn_vm "jenkins-01" "$CENTRAL_VAGRANTFILE"
    spawn_vm "node-a" "$STUDENT_VAGRANTFILE"
    spawn_vm "node-b" "$STUDENT_VAGRANTFILE"
    build_ssh_cfg "jenkins-01" "$CENTRAL_VAGRANTFILE"
    build_ssh_cfg "node-a" "$STUDENT_VAGRANTFILE"
    build_ssh_cfg "node-b" "$STUDENT_VAGRANTFILE"

    # Step 4b: register central's Gerrit Trigger SSH key for this VM's
    # lifetime — unguarded; set -e aborts the run if this fails, since a
    # test run is meaningless without a working central Gerrit key.
    sudo /opt/ci/register_central_key.sh

    # Step 5: deploy central Jenkins inside its VM
    build_central_vm_secrets
    deploy_central "jenkins-01" "$CENTRAL_VM_SECRETS"

    # Step 6: provision node-a and node-b as real students via
    # setup_students.sh. Sets NODEA_NAME/NODEB_NAME and each one's
    # generated secrets.yml — deployed exactly as a student would.
    provision_test_students

    deploy_agent "node-a" "$NODEA_SECRETS_FILE"
    deploy_agent "node-b" "$NODEB_SECRETS_FILE"
    wait_for_agent_online "$NODEA_NAME" 24
    wait_for_agent_online "$NODEB_NAME" 24
    verify_executor_counts "$NODEA_NAME" "$NODEB_NAME"

    # Matches the literal jobs/jenkins-dr-test/Jenkinsfile's Dummy stage
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

    # Step 11: remove both test students again — exercises reset_students.sh.
    reset_test_students

    print_final_status "✓ Central + both agents deployed and online; all 3 identities pushed together, routing verified."
}

main "$@"
