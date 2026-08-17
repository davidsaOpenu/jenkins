#!/usr/bin/env bash
# Shared VM-lifecycle + test-orchestration functions for run.sh. Sourced
# only. Functions read shared config (SCRIPT_DIR, WORKDIR, JENKINS_URL,
# ADMIN_USER/PASS, ...) as globals set by common_setup() / run.sh's main().

# The host exports a broken proxy — curl silently honors it for plain-http
# URLs even though every target here is an unreachable local VM, hanging
# each request for minutes. Strip the whole family.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

title() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo " $1"
    echo "════════════════════════════════════════════════════════════"
}

# Tears down any VMs left over from a previous run via the real cleanup
# scripts (proper `vagrant destroy` + virsh fallback), not spawn_vm's own
# narrower stale-domain check — keeps Vagrant's own state consistent.
clean_start() {
    title "Clean start — tearing down any leftover VMs"
    bash "${SCRIPT_DIR}/cleanup.sh"
    bash "${SCRIPT_DIR}/student_deploy/cleanup.sh"
}

# Step 0: parse the one flag run.sh takes. No file arguments — the
# credentials files always live at fixed, known repo paths (set below in
# common_setup), never passed in.
parse_args() {
    LOCAL_REPO=false
    for arg in "$@"; do
        case "$arg" in
            --local-repo) LOCAL_REPO=true ;;
            *) echo "Usage: ./run.sh [--local-repo]" >&2; exit 1 ;;
        esac
    done
}

# Prologue every run needs, in this fixed order: lock, trap, Step 1's local
# setup.
common_setup() {
    cd "$SCRIPT_DIR"

    # Guards against a daily cron self-check and a manual run ever
    # overlapping on the same host — released automatically when the script
    # exits, whatever the reason.
    LOCK_FILE="/tmp/jenkins-dr-run.lock"
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        echo "✗ Another run is already in progress (lock: ${LOCK_FILE})"
        exit 1
    fi

    GIT_DAEMON_PID=""
    WORKDIR=$(mktemp -d)

    # Registered before anything (git daemon, VM relay) that could exit
    # early, so nothing started below this point can ever leak past a
    # failure.
    trap 'rm -rf "$WORKDIR"; [[ -n "$GIT_DAEMON_PID" ]] && kill "$GIT_DAEMON_PID" 2>/dev/null; true' EXIT

    title "Local setup"
    # Overwrites scripts/cleanup.sh's empty stub with the real thing, so
    # jobs/jenkins/Jenkinsfile's post.always (dir('jenkins/scripts') { sh
    # './cleanup.sh' }) tears down real VMs instead of running a no-op.
    mkdir -p "${SCRIPT_DIR}/scripts"
    cp "${SCRIPT_DIR}/cleanup.sh" "${SCRIPT_DIR}/scripts/cleanup.sh"
    chmod +x "${SCRIPT_DIR}/scripts/cleanup.sh"

    CENTRAL_VAGRANTFILE="central_deploy/Vagrantfile.jenkins"
    STUDENT_VAGRANTFILE="student_deploy/Vagrantfile"
    # vagrant-libvirt connects here (both Vagrantfiles set qemu_use_session =
    # false) — bare `virsh` defaults to qemu:///session instead, a completely
    # separate per-user scope that never sees these domains.
    LIBVIRT_URI="qemu:///system"
    CENTRAL_IP="${CENTRAL_IP:-192.168.100.170}"
    DEFAULTS_FILE="central_deploy/roles/jenkins/defaults/main.yml"
    JENKINS_PORT="${JENKINS_PORT:-$(python3 -c "import yaml; print(yaml.safe_load(open('${DEFAULTS_FILE}'))['jenkins_http_port'])")}"
    JENKINS_URL="http://${CENTRAL_IP}:${JENKINS_PORT}"
    DUMMY_JOB="swiftacular-dummy"
    # Login password for both test-student accounts — also what
    # verify_node_routing submits when approving each one's own build (the
    # Approval stage's `input submitter:` restriction).
    STUDENT_TEST_PASSWORD="run-sh-test-password"
}

# Step: optionally serve this checkout over a local git daemon instead of
# pointing the dummy job at the real GerritHub master — lets --local-repo
# validate uncommitted changes before they're ever pushed/merged.
start_local_git_daemon() {
    sudo firewall-cmd --add-port=9418/tcp --zone=libvirt 2>/dev/null || true
    touch "${SCRIPT_DIR}/.git/git-daemon-export-ok"
    # A daemon always serves the live filesystem state, no caching — if
    # something's already listening (maybe a different user, maybe a
    # different workspace's checkout of this same repo), reuse it instead
    # of fighting over the port: we may not even have permission to kill it.
    if ss -tln 2>/dev/null | grep -q ':9418 '; then
        echo "→ --local-repo: reusing the git daemon already serving :9418"
        GIT_DAEMON_PID=""
        return 0
    fi
    echo "→ --local-repo: serving this checkout over a local git daemon..."
    # 200>&- closes the lock fd in the backgrounded daemon: without it, the
    # long-running child inherits fd 200 and keeps the flock held even after
    # this script's own EXIT trap kills it (kill isn't instant).
    git daemon --reuseaddr --base-path="$(dirname "$SCRIPT_DIR")" --export-all --port=9418 "$SCRIPT_DIR" 200>&- &
    GIT_DAEMON_PID=$!
    echo "→ Serving at git://192.168.100.1/jenkins (PID ${GIT_DAEMON_PID})"
}

# Step: writes the central secrets file pushed into the VM — generated from
# CENTRAL_* (set by load_gerrit_users), dummy_job_repo_url set to the
# git-daemon URL only when --local-repo is set. Sets CENTRAL_VM_SECRETS.
build_central_vm_secrets() {
    CENTRAL_VM_SECRETS="${WORKDIR}/gerrit_central_test.yml"
    local repo_url=""
    [[ "$LOCAL_REPO" == "true" ]] && repo_url="git://192.168.100.1/jenkins"
    python3 - "$CENTRAL_VM_SECRETS" \
        "$CENTRAL_JENKINS_ADMIN_PASSWORD" \
        "$CENTRAL_GERRIT_USERNAME" "$CENTRAL_SSH_KEY_NAME" "$CENTRAL_GERRIT_EMAIL" \
        "$CENTRAL_GERRIT_DISPLAY_NAME" "$CENTRAL_CHANGE_ID" "$repo_url" <<'PYEOF'
import sys, yaml
dst, admin_pass, username, key_name, email, display_name, change_id, repo_url = sys.argv[1:9]
d = {
    'jenkins_admin_password': admin_pass,
    'gerrit_username': username,
    'ssh_key_name': key_name,
    'email': email,
    'display_name': display_name,
    'change_id': change_id,
}
# Omit entirely when unset — Ansible's -e extra-vars override role defaults
# even with an empty string, so writing '' here would permanently blank out
# the role's real-repo default instead of falling back to it.
if repo_url:
    d['dummy_job_repo_url'] = repo_url
yaml.safe_dump(d, open(dst, 'w'))
PYEOF
}

# Step: writes the secrets.yml-shaped file a node's deploy_agent.sh needs.
build_node_secrets() {
    local out_file="$1" owner="$2" agent_name="$3" agent_secret="$4"
    cat > "$out_file" <<EOF
gerrit_owner_username: "${owner}"
central_url: "${JENKINS_URL}"
central_agent_name: "${agent_name}"
central_agent_secret: "${agent_secret}"
EOF
}

# Step: for a build that already exists (pushed via gerrit_multi_user_push.sh,
# mapped to this identity by map_builds_to_owners) — optionally proves
# wrong_user can't approve it, then confirms it ran on expected_node.
verify_node_routing() {
    local expected_node="$1" build_number="$2" submit_user="$3" submit_pass="$4" wrong_user="${5:-}" wrong_pass="${6:-}"

    wait_for_pending_input "$DUMMY_JOB" "$build_number" || exit 1
    local input_id="$INPUT_ID"

    if [[ -n "$wrong_user" ]]; then
        # Jenkins accepts this submit at the HTTP level regardless (see
        # Jenkinsfile) — the real check is that the pipeline rejects it
        # and re-pauses on a fresh input instead of proceeding.
        echo "→ Confirming ${wrong_user} cannot approve ${submit_user}'s build..."
        submit_input_as "$DUMMY_JOB" "$build_number" "$input_id" "$wrong_user" "$wrong_pass" || true
        wait_for_pending_input "$DUMMY_JOB" "$build_number" \
            || { echo "✗ ${wrong_user} was WRONGLY able to approve this build"; exit 1; }
        input_id="$INPUT_ID"
        echo "  (correctly rejected — build re-paused for a fresh attempt)"
    fi

    echo "→ Approving as ${submit_user}..."
    submit_input_as "$DUMMY_JOB" "$build_number" "$input_id" "$submit_user" "$submit_pass" \
        || { echo "✗ ${submit_user} could not approve their own build (HTTP ${SUBMIT_HTTP_CODE})"; exit 1; }
    sleep 2
    confirm_input_cleared "$DUMMY_JOB" "$build_number" \
        || { echo "✗ Approval as ${submit_user} did not clear the pending input — Approval stage never proceeded"; exit 1; }
    echo "  (approval confirmed — pending input cleared)"

    wait_for_build_finish "$DUMMY_JOB" "$build_number"
    report_build_result "$DUMMY_JOB" "$build_number"
    check_build_ran_on "$DUMMY_JOB" "$build_number" "$expected_node"
}

# One-time, self-healing: builds and caches the centos9-java21 box on first
# use so later runs skip straight to spawn_vm. Bakes in ansible/git too —
# one shared box beats maintaining two.
ensure_java_box() {
    vagrant box list | grep -q '^centos9-java21' && return 0
    title "Building centos9-java21 box (one-time)"
    local box_dir
    box_dir=$(mktemp -d -p "$WORKDIR")
    cat > "${box_dir}/Vagrantfile" <<'EOF'
Vagrant.configure("2") do |config|
  config.vm.box = "eurolinux-vagrant/centos-stream-9"
  config.vm.provider :libvirt do |v|
    v.qemu_use_session = false
    v.memory = 1024
    v.cpus = 1
  end
  config.vm.synced_folder ".", "/vagrant", disabled: true
end
EOF
    # set -e aborts on the first failure without a RETURN trap, so cleanup
    # is explicit at each step — otherwise a failed vagrant call leaves the
    # throwaway VM behind for good.
    destroy_vm() { (cd "$box_dir" && vagrant destroy -f) 2>/dev/null || true; }

    # vagrant's libvirt image-copy step spams one "Progress: N%" line per
    # point, flooding the console log — collapse it to the last line only.
    (cd "$box_dir" && { vagrant up | grep -v --line-buffered -E 'Progress:'; } ; exit "${PIPESTATUS[0]}") || { destroy_vm; return 1; }
    (cd "$box_dir" && vagrant ssh -c "sudo dnf install -y epel-release && sudo dnf install -y java-21-openjdk ansible git && sudo dnf clean all") || { destroy_vm; return 1; }
    (cd "$box_dir" && vagrant halt) || { destroy_vm; return 1; }
    (cd "$box_dir" && { vagrant package --output centos9-java21.box | grep -v --line-buffered -E 'Progress:'; } ; exit "${PIPESTATUS[0]}") || { destroy_vm; return 1; }
    vagrant box add centos9-java21 "${box_dir}/centos9-java21.box" || { destroy_vm; return 1; }
    destroy_vm

    vagrant box list | grep -q '^centos9-java21' \
        || { echo "✗ centos9-java21 box build finished but the box still isn't in the cache"; return 1; }
}

spawn_vm() {
    local vm_name="$1" vagrantfile="$2"
    title "Spawn VM (${vm_name})"
    # vagrant-libvirt names domains "<cwd-basename>_<machine-name>"; compute
    # the exact name so cleanup never touches an unrelated VM on this host.
    local domain_name
    domain_name="$(basename "$SCRIPT_DIR")_${vm_name}"
    if virsh -c "$LIBVIRT_URI" dominfo "$domain_name" &>/dev/null; then
        echo "→ Removing stale libvirt domain '${domain_name}' from a previous run..."
        virsh -c "$LIBVIRT_URI" destroy "$domain_name" 2>/dev/null || true
        virsh -c "$LIBVIRT_URI" undefine "$domain_name" --remove-all-storage 2>/dev/null || true
    fi
    # Same libvirt image-copy spam as ensure_java_box — filtered the same way.
    { VAGRANT_VAGRANTFILE="$vagrantfile" vagrant up "$vm_name" | grep -v --line-buffered -E 'Progress:'; } ; return "${PIPESTATUS[0]}"
}

# Fetches vm_name's SSH config into a WORKDIR-scoped file, reusable directly
# as `ssh -F <that file> <vm_name>` / `rsync -e "ssh -F <that file>"`.
build_ssh_cfg() {
    local vm_name="$1" vagrantfile="$2"
    VAGRANT_VAGRANTFILE="$vagrantfile" vagrant ssh-config "$vm_name" > "${WORKDIR}/${vm_name}.ssh_cfg"
}

push_repo_into_vm() {
    local vm_name="$1"
    rsync -a --exclude '.git' --exclude '.vagrant' -e "ssh -F ${WORKDIR}/${vm_name}.ssh_cfg" \
        "${SCRIPT_DIR}/" "${vm_name}:/home/vagrant/jenkins-dr/"
}

# Runs $2 inside vm_name (already rsync'd to /home/vagrant/jenkins-dr),
# propagating its exit code.
run_in_vm() {
    local vm_name="$1" cmd="$2"
    local rc=0
    ssh -F "${WORKDIR}/${vm_name}.ssh_cfg" "$vm_name" "cd /home/vagrant/jenkins-dr && ${cmd}" || rc=$?
    return "$rc"
}

deploy_central() {
    local vm_name="$1" secrets_file="$2"
    title "Deploy central Jenkins (${vm_name})"
    push_repo_into_vm "$vm_name"
    scp -q -F "${WORKDIR}/${vm_name}.ssh_cfg" "$secrets_file" "${vm_name}:/home/vagrant/jenkins-dr/gerrit_central_test.yml"

    # secrets_file only names the key (ssh_key_name) — copy the actual
    # private key in separately, to root's ~/.ssh. Two-hop: scp connects as
    # vagrant, so land it in /tmp first, then sudo mv into place.
    run_in_vm "$vm_name" "sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh"
    scp -q -F "${WORKDIR}/${vm_name}.ssh_cfg" "$CENTRAL_GERRIT_KEY_FILE" \
        "${vm_name}:/tmp/${CENTRAL_SSH_KEY_NAME}"
    run_in_vm "$vm_name" "sudo mv /tmp/${CENTRAL_SSH_KEY_NAME} /root/.ssh/${CENTRAL_SSH_KEY_NAME} && sudo chmod 600 /root/.ssh/${CENTRAL_SSH_KEY_NAME}"

    # -H forces HOME=/root explicitly — deploy_central_jenkins.sh resolves
    # the key via ${HOME}/.ssh/, and this box's sudo default isn't assumed.
    run_in_vm "$vm_name" "sudo -H ./central_deploy/deploy_central_jenkins.sh gerrit_central_test.yml"
}

# Same shape as deploy_central — push repo + secrets, run the deploy script
# locally inside the VM.
deploy_agent() {
    local vm_name="$1" secrets_file="$2"
    title "Deploy agent (${vm_name})"
    push_repo_into_vm "$vm_name"
    scp -q -F "${WORKDIR}/${vm_name}.ssh_cfg" "$secrets_file" "${vm_name}:/home/vagrant/jenkins-dr/agent_secrets_test.yml"
    run_in_vm "$vm_name" "sudo ./student_deploy/deploy_agent.sh agent_secrets_test.yml"
}

wait_for_agent_online() {
    local node_name="$1" timeout_iterations="$2"
    title "Wait for agent online (${node_name})"
    local i
    for ((i = 0; i < timeout_iterations; i++)); do
        local offline
        offline=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/computer/${node_name}/api/json" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('offline', True))" 2>/dev/null || echo True)
        [[ "$offline" == "False" ]] && { echo "→ ${node_name} online"; return 0; }
        sleep 5
    done
    echo "✗ Agent ${node_name} never came online" >&2
    return 1
}

# Step: builds a students.yaml-shaped config from node A/B's identities,
# then runs the real central_deploy/setup_students.sh — not a hand-rolled
# shortcut. Sets NODEA_NAME/NODEA_SECRET and NODEB_NAME/NODEB_SECRET.
provision_test_students() {
    title "Provision test students via setup_students.sh"

    local config="${WORKDIR}/students_test.yaml"
    local creds="${WORKDIR}/students_credentials_test.yaml"

    cat > "$config" <<EOF
central_url: "${JENKINS_URL}"
admin_user: "${ADMIN_USER}"
admin_password: "${ADMIN_PASS}"
students:
  - name: "${NODE_A_GERRIT_USERNAME}"
    project: "swiftacular_dummy"
    password: "${STUDENT_TEST_PASSWORD}"
  - name: "${NODE_B_GERRIT_USERNAME}"
    project: "swiftacular_dummy"
    password: "${STUDENT_TEST_PASSWORD}"
EOF

    bash "${SCRIPT_DIR}/central_deploy/setup_students.sh" "$config" "$creds"

    local creds_vars
    creds_vars=$(python3 - "$creds" "$NODE_A_GERRIT_USERNAME" "$NODE_B_GERRIT_USERNAME" <<'PYEOF'
import sys, yaml
path, node_a, node_b = sys.argv[1:4]
d = yaml.safe_load(open(path))
print(f'NODEA_NAME\t{d[node_a]["agent_name"]}')
print(f'NODEA_SECRET\t{d[node_a]["agent_secret"]}')
print(f'NODEB_NAME\t{d[node_b]["agent_name"]}')
print(f'NODEB_SECRET\t{d[node_b]["agent_secret"]}')
PYEOF
    )
    while IFS=$'\t' read -r key value; do
        printf -v "$key" '%s' "$value"
    done <<< "$creds_vars"
}
