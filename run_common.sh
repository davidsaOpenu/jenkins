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

# Step 0: run.sh takes no flags. No file arguments either — the credentials
# files always live at fixed, known repo paths (set below in common_setup),
# never passed in.
parse_args() {
    [[ $# -eq 0 ]] || { echo "Usage: ./run.sh" >&2; exit 1; }
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

    WORKDIR=$(mktemp -d)

    # Registered before anything that could exit early, so nothing started
    # below this point can ever leak past a failure.
    trap 'rm -rf "$WORKDIR"' EXIT

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
    JENKINS_URL="https://${CENTRAL_IP}"
    # Where deploy_central_jenkins.sh puts the self-signed certificate it
    # makes when the config names none (its GENERATED_TLS_DIR) — fetched
    # from the central VM after deploy, then handed to each agent VM.
    CENTRAL_GENERATED_CERT="/etc/jenkins-dr/tls/jenkins-dr.crt"
    AGENT_CA_CERT="/home/vagrant/jenkins-dr/central-ca.crt"
    DUMMY_JOB="jenkins-dr-test"
    # Login password for both test-student accounts — also what
    # verify_node_routing submits when approving each one's own build (the
    # Approval stage's `input submitter:` restriction).
    STUDENT_TEST_PASSWORD="run-sh-test-password"
}

# Step: writes the central secrets file pushed into the VM — generated from
# CENTRAL_* (set by load_gerrit_users), in exactly gerrit_central.yml's
# shape. TLS is left blank, same as an operator without a real certificate:
# deploy_central_jenkins.sh makes the self-signed one itself, so CI covers
# that path too. Sets CENTRAL_VM_SECRETS.
build_central_vm_secrets() {
    CENTRAL_VM_SECRETS="${WORKDIR}/gerrit_central_test.yml"
    python3 - "$CENTRAL_VM_SECRETS" \
        "$CENTRAL_JENKINS_ADMIN_PASSWORD" \
        "$CENTRAL_GERRIT_USERNAME" "$CENTRAL_SSH_KEY_NAME" "$CENTRAL_GERRIT_EMAIL" \
        "$CENTRAL_GERRIT_DISPLAY_NAME" "$CENTRAL_CHANGE_ID" \
        "$CENTRAL_IP" <<'PYEOF'
import sys, yaml
dst, admin_pass, username, key_name, email, display_name, change_id, ip = sys.argv[1:9]
d = {
    'jenkins_admin_password': admin_pass,
    'gerrit_username': username,
    'ssh_key_name': key_name,
    'email': email,
    'display_name': display_name,
    'change_id': change_id,
    'jenkins_url': f'https://{ip}',
    'tls_cert_file': '',
    'tls_key_file': '',
}
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
central_ca_cert: "${AGENT_CA_CERT}"
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
        # Jenkins may refuse this submit outright (`input submitter:`) or
        # accept it at the HTTP level — the real check is that the build
        # is still paused afterwards instead of proceeding.
        echo "→ Confirming ${wrong_user} cannot approve ${submit_user}'s build..."
        submit_input_as "$DUMMY_JOB" "$build_number" "$input_id" "$wrong_user" "$wrong_pass" || true
        wait_for_pending_input "$DUMMY_JOB" "$build_number" \
            || { echo "✗ ${wrong_user} was WRONGLY able to approve this build"; exit 1; }
        input_id="$INPUT_ID"
        echo "  (correctly rejected — build re-paused for a fresh attempt)"
        verify_student_read_only "$DUMMY_JOB" "$build_number" "$wrong_user" "$wrong_pass"
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

# Step: proves a logged-in student is read-only on another student's
# (paused) build — sees its console log, but can neither start a build of
# the job nor stop this one (jenkins.yaml.j2 grants Overall/Read + Job/Read
# only).
verify_student_read_only() {
    local job_name="$1" build_number="$2" username="$3" password="$4"
    local cookie_jar crumb code
    echo "→ Confirming ${username} can read ${job_name} #${build_number}'s log but not start or stop builds..."
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "${username}:${password}" \
        "${JENKINS_URL}/job/${job_name}/${build_number}/consoleText")
    [[ "$code" == "200" ]] || { echo "✗ ${username} cannot read build #${build_number}'s log (HTTP ${code})"; exit 1; }

    # A real crumb, or the 403s below would only prove CSRF protection.
    cookie_jar=$(mktemp -p "$WORKDIR")
    crumb=$(curl -sf -u "${username}:${password}" -c "$cookie_jar" -b "$cookie_jar" \
        "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])" 2>/dev/null)
    [[ -n "$crumb" ]] || { echo "✗ ${username} could not get a crumb — cannot run the permission check"; exit 1; }

    code=$(curl -s -o /dev/null -w '%{http_code}' -u "${username}:${password}" -c "$cookie_jar" -b "$cookie_jar" -H "$crumb" \
        -X POST "${JENKINS_URL}/job/${job_name}/buildWithParameters")
    [[ "$code" == "403" ]] || { echo "✗ ${username} was WRONGLY able to start a ${job_name} build (HTTP ${code})"; exit 1; }
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "${username}:${password}" -c "$cookie_jar" -b "$cookie_jar" -H "$crumb" \
        -X POST "${JENKINS_URL}/job/${job_name}/${build_number}/stop")
    [[ "$code" == "403" ]] || { echo "✗ ${username} was WRONGLY able to stop build #${build_number} (HTTP ${code})"; exit 1; }
    rm -f "$cookie_jar"
    echo "  (read-only, as expected — log readable, start/stop refused)"
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

    # The exact command DEPLOY_CENTRAL.md gives for a real machine, flag
    # included: on this fresh VM every --replace-old-jenkins step finds
    # nothing, but CI still runs them. The key is already in /root/.ssh
    # and registered (register_central_key.sh), so no prompt is needed.
    run_in_vm "$vm_name" "sudo ./central_deploy/setup_central.sh gerrit_central_test.yml --replace-old-jenkins"

    fetch_central_ca_cert "$vm_name"
}

# Copies the self-signed certificate deploy_central_jenkins.sh made inside
# the central VM. Sets CENTRAL_CA_CERT (a copy on this host) and makes every
# later curl here trust it via CURL_CA_BUNDLE.
fetch_central_ca_cert() {
    local vm_name="$1"
    CENTRAL_CA_CERT="${WORKDIR}/central-ca.crt"
    run_in_vm "$vm_name" "sudo cat ${CENTRAL_GENERATED_CERT}" > "$CENTRAL_CA_CERT"

    # The host's own CA list comes along, so anything else curl talks to
    # is trusted exactly as before.
    local host_cas
    for host_cas in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
        [[ -f "$host_cas" ]] && break
    done
    cat "$host_cas" "$CENTRAL_CA_CERT" > "${WORKDIR}/ca-bundle.crt"
    export CURL_CA_BUNDLE="${WORKDIR}/ca-bundle.crt"
}

# Same shape as deploy_central — push repo + secrets, run the deploy script
# locally inside the VM.
deploy_agent() {
    local vm_name="$1" secrets_file="$2"
    title "Deploy agent (${vm_name})"
    push_repo_into_vm "$vm_name"
    scp -q -F "${WORKDIR}/${vm_name}.ssh_cfg" "$CENTRAL_CA_CERT" "${vm_name}:${AGENT_CA_CERT}"
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

# Step: every node — the built-in one (jenkins.yaml.j2) and each named
# agent (setup_students.sh) — must exist and have exactly 1 executor.
verify_executor_counts() {
    title "Verify every node has exactly 1 executor"
    local computers
    # -g: without it curl reads the tree=...[...] brackets as a URL glob.
    computers=$(curl -sfg -u "${ADMIN_USER}:${ADMIN_PASS}" \
        "${JENKINS_URL}/computer/api/json?tree=computer[_class,displayName,numExecutors]") \
        || { echo "✗ Could not list Jenkins' nodes" >&2; exit 1; }
    python3 -c '
import json, sys
computers = json.loads(sys.argv[1])["computer"]
expected = sys.argv[2:]
bad = []
for c in computers:
    builtin = c["_class"].endswith("MasterComputer")
    name = "built-in" if builtin else c["displayName"]
    count = c["numExecutors"]
    print(f"  {name}: {count} executor(s)")
    if count != 1:
        bad.append(name)
names = {c["displayName"] for c in computers}
missing = [n for n in expected if n not in names]
if not any(c["_class"].endswith("MasterComputer") for c in computers):
    missing.append("built-in")
if bad or missing:
    sys.exit(f"✗ Not exactly 1 executor: {bad}; missing nodes: {missing}")
' "$computers" "$@" || exit 1
    echo "→ All nodes have exactly 1 executor"
}

# Step: builds a students.yaml-shaped config from node A/B's identities,
# then runs the real central_deploy/setup_students.sh — not a hand-rolled
# shortcut. Sets NODEA_NAME/NODEA_SECRET and NODEB_NAME/NODEB_SECRET.
provision_test_students() {
    title "Provision test students via setup_students.sh"

    local config="${WORKDIR}/students_test.yaml"
    local creds="${WORKDIR}/students_credentials_test.yaml"

    cat > "$config" <<EOF
students:
  - name: "${NODE_A_GERRIT_USERNAME}"
    project: "jenkins_dr_test"
    password: "${STUDENT_TEST_PASSWORD}"
  - name: "${NODE_B_GERRIT_USERNAME}"
    project: "jenkins_dr_test"
    password: "${STUDENT_TEST_PASSWORD}"
EOF

    JENKINS_URL="$JENKINS_URL" JENKINS_ADMIN_USER="$ADMIN_USER" JENKINS_ADMIN_PASSWORD="$ADMIN_PASS" \
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

# Removes both test students with the same reset_students.sh the instructor
# runs, then checks Jenkins no longer has their nodes.
reset_test_students() {
    title "Remove test students via reset_students.sh"

    JENKINS_URL="$JENKINS_URL" JENKINS_ADMIN_USER="$ADMIN_USER" JENKINS_ADMIN_PASSWORD="$ADMIN_PASS" \
        bash "${SCRIPT_DIR}/central_deploy/reset_students.sh" "$NODE_A_GERRIT_USERNAME" "$NODE_B_GERRIT_USERNAME"

    local node
    for node in "$NODEA_NAME" "$NODEB_NAME"; do
        if curl -sf -o /dev/null -u "${ADMIN_USER}:${ADMIN_PASS}" "${JENKINS_URL}/computer/${node}/api/json"; then
            echo "✗ node ${node} still exists after reset_students.sh"; exit 1
        fi
    done
    echo "→ both test students removed"
}
