#!/usr/bin/env bash
# Test harness: proves the deploy scripts work by running them unmodified
# inside disposable VMs (left running afterward — use cleanup.sh /
# student_deploy/cleanup.sh to tear down). Credentials come from the fixed
# files central_deploy/gerrit_central.yml / gerrit_agents.yml, never args.
#
# Usage: ./run.sh [--local-repo]
#
# Step implementations live in run_common.sh / deploy_verify.sh — this
# file is just the flow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/run_common.sh"
source "${SCRIPT_DIR}/deploy_verify.sh"

main() {
    parse_args "$@"
    common_setup "$@"

    # Step 1: tear down any VMs left over from a previous run, so every run
    # starts from a genuinely clean, consistent state
    clean_start

    # Step 2: optionally serve this checkout over a local git daemon
    [[ "$LOCAL_REPO" == "true" ]] && start_local_git_daemon

    # Step 3: load Gerrit credentials for central + both nodes, then confirm
    # each one is actually usable before any VM is spawned — a bad
    # credential fails here in seconds instead of ~20 minutes in.
    load_central_account "$CENTRAL_ACCOUNTS_FILE"
    load_agent_accounts "$AGENTS_ACCOUNTS_FILE"
    ADMIN_USER="$CENTRAL_JENKINS_ADMIN_USER"
    ADMIN_PASS="$CENTRAL_JENKINS_ADMIN_PASSWORD"

    validate_gerrit_account "central" "$CENTRAL_GERRIT_KEY_FILE" "$CENTRAL_GERRIT_USERNAME" "$CENTRAL_DUMMY_CHANGE_NUMBER"
    validate_gerrit_account "node-a" "$NODE_A_KEY_FILE" "$NODE_A_GERRIT_USERNAME" "$NODE_A_DUMMY_CHANGE_NUMBER"
    validate_gerrit_account "node-b" "$NODE_B_KEY_FILE" "$NODE_B_GERRIT_USERNAME" "$NODE_B_DUMMY_CHANGE_NUMBER"

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
    # setup_students.sh, deploy both — node-b comes online exactly like
    # node-a, it's just never the target of an event in this test. Sets
    # NODEA_NAME/NODEA_SECRET and NODEB_NAME/NODEB_SECRET.
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

    # Step 7: fire three real Gerrit events, one per identity — central and
    # each node have their own distinct identity/label, so each check is
    # fully deterministic: only the matching node's label can ever be
    # scheduled, the other two staying silent is guaranteed by construction
    # (exactly one build fires per event). Registered once, not per event —
    # the trigger only needs one build ever to make Jenkins pick it up.
    register_gerrit_trigger "$DUMMY_JOB"

    # Central approves as its own Gerrit-identity account (JCasC-created,
    # same password as admin) — no distinct non-admin account to cross-test
    # against, so it skips the wrong_user/wrong_pass negative-path args.
    title "Central event — expect it built on the built-in node (${CENTRAL_NAME}); node-a and node-b should never be candidates"
    verify_node_routing "$CENTRAL_NAME" "$CENTRAL_GERRIT_USERNAME" "$CENTRAL_GERRIT_KEY_FILE" "$CENTRAL_GERRIT_EMAIL" "$CENTRAL_DUMMY_CHANGE_NUMBER" \
        "$CENTRAL_GERRIT_USERNAME" "$ADMIN_PASS"

    # Node A/B cross-test each other: node B must NOT be able to approve
    # node A's build (and vice versa) before the real submitter approves it.
    title "Node A event — expect it built on ${NODEA_NAME}; node-b and the built-in node should never be candidates"
    verify_node_routing "$NODEA_NAME" "$NODE_A_GERRIT_USERNAME" "$NODE_A_KEY_FILE" "$NODE_A_GERRIT_EMAIL" "$NODE_A_DUMMY_CHANGE_NUMBER" \
        "$NODE_A_GERRIT_USERNAME" "$STUDENT_TEST_PASSWORD" "$NODE_B_GERRIT_USERNAME" "$STUDENT_TEST_PASSWORD"

    title "Node B event — expect it built on ${NODEB_NAME}; node-a and the built-in node should never be candidates"
    verify_node_routing "$NODEB_NAME" "$NODE_B_GERRIT_USERNAME" "$NODE_B_KEY_FILE" "$NODE_B_GERRIT_EMAIL" "$NODE_B_DUMMY_CHANGE_NUMBER" \
        "$NODE_B_GERRIT_USERNAME" "$STUDENT_TEST_PASSWORD" "$NODE_A_GERRIT_USERNAME" "$STUDENT_TEST_PASSWORD"

    print_final_status "✓ Central + both agents deployed and online; central + both node events fired and routing verified."
}

main "$@"
