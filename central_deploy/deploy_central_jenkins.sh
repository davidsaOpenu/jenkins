#!/usr/bin/env bash
# Installs central Jenkins + the dummy job + Gerrit wiring, wherever this is
# run — VM, bare metal, cloud box, doesn't matter. This is the actual
# disaster-recovery tool: when central Jenkins is down, fill in
# gerrit_central.yml (and optionally gerrit_agents.yml) and run this script.
#
# Usage: sudo ./deploy_central_jenkins.sh <path-to-gerrit_central.yml> [path-to-gerrit_agents.yml]
#
# gerrit_agents.yml is optional — when given, its accounts are validated the
# same way central's is, and the run-sh-gerrit-agents Jenkins credential is
# (re)created from it, same as run-sh-gerrit-central always is. Omit it and
# deploy still succeeds central-only; run-sh-gerrit-agents then needs its
# usual one-time manual upload (see README.md) before the daily self-check
# job can run.
#
# Always verifies at the end by pushing a real Gerrit patchset and confirming
# the dummy job builds — this is the actual production tool, not a test
# double, so there's no "skip verify" mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "${REPO_ROOT}/deploy_verify.sh"

# Broken proxy env — see run_common.sh for why. Strip it.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

parse_args() {
    if [[ $# -lt 1 || $# -gt 2 ]]; then
        echo "Usage: sudo ./deploy_central_jenkins.sh <path-to-gerrit_central.yml> [path-to-gerrit_agents.yml]" >&2
        exit 1
    fi
    ACCOUNTS_FILE="$1"
    [[ -f "$ACCOUNTS_FILE" ]] || { echo "✗ Not found: $ACCOUNTS_FILE" >&2; exit 1; }
    AGENTS_FILE="${2:-}"
    [[ -z "$AGENTS_FILE" || -f "$AGENTS_FILE" ]] || { echo "✗ Not found: $AGENTS_FILE" >&2; exit 1; }
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "✗ Must run as root (installs packages, systemd units): sudo $0 ${ACCOUNTS_FILE} ${AGENTS_FILE}" >&2
        exit 1
    fi
}

# A disaster-recovery script can't assume the target machine has anything
# beyond a base OS — install whatever's missing rather than failing.
install_prereqs() {
    # git-review is required too — verify_deploy pushes its verification
    # patchset via the real `git review` binary, not a raw `git push`.
    declare -A pkg_for_cmd=( [ansible-playbook]=ansible [python3]=python3 [curl]=curl [git]=git [git-review]=git-review )
    local missing_pkgs=()
    local cmd
    for cmd in ansible-playbook python3 curl git git-review; do
        command -v "$cmd" >/dev/null 2>&1 || missing_pkgs+=("${pkg_for_cmd[$cmd]}")
    done
    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        # ansible/git-review aren't in CentOS Stream's base/AppStream repos —
        # need EPEL first, same as the ansible role's own "Install EPEL" →
        # "Install Ansible" task order. Not needed/available on Fedora,
        # which already has both in its base repos.
        if [[ "${missing_pkgs[*]}" =~ (^|[[:space:]])(ansible|git-review)($|[[:space:]]) ]] \
            && [[ "$(. /etc/os-release && echo "$ID")" != "fedora" ]] \
            && ! dnf list installed epel-release >/dev/null 2>&1; then
            echo "→ Installing EPEL (required for the ansible/git-review packages)..."
            dnf install -y epel-release
        fi
        echo "→ Installing missing prerequisites: ${missing_pkgs[*]}..."
        dnf install -y "${missing_pkgs[@]}"
    fi
}

detect_public_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$ip" ]]; then
        echo "✗ Could not auto-detect this machine's IP" >&2
        exit 1
    fi
    echo "$ip"
}

run_deploy() {
    echo "→ Loading ${ACCOUNTS_FILE}..."
    load_central_account "$ACCOUNTS_FILE"
    validate_gerrit_account "central" "$CENTRAL_GERRIT_KEY_FILE" "$CENTRAL_GERRIT_USERNAME" "$CENTRAL_DUMMY_CHANGE_NUMBER"

    PUBLIC_IP=$(detect_public_ip)
    echo "→ Deploying as ${PUBLIC_IP}..."

    local extra_vars=(-e "@${ACCOUNTS_FILE}" -e "jenkins_public_ip=${PUBLIC_IP}" -e "central_accounts_file=$(realpath "$ACCOUNTS_FILE")")

    if [[ -n "$AGENTS_FILE" ]]; then
        echo "→ Loading ${AGENTS_FILE}..."
        load_agent_accounts "$AGENTS_FILE"
        validate_gerrit_account "node-a" "$NODE_A_KEY_FILE" "$NODE_A_GERRIT_USERNAME" "$NODE_A_DUMMY_CHANGE_NUMBER"
        validate_gerrit_account "node-b" "$NODE_B_KEY_FILE" "$NODE_B_GERRIT_USERNAME" "$NODE_B_DUMMY_CHANGE_NUMBER"
        extra_vars+=(-e "agents_accounts_file=$(realpath "$AGENTS_FILE")")
    fi

    ansible-playbook -i "localhost," -c local -b \
        "${extra_vars[@]}" \
        "${REPO_ROOT}/central_deploy/deploy_jenkins.yml"
}

verify_deploy() {
    echo "→ Verifying: pushing a real Gerrit patchset and waiting for the dummy job to build..."
    ADMIN_USER="$CENTRAL_JENKINS_ADMIN_USER"
    ADMIN_PASS="$CENTRAL_JENKINS_ADMIN_PASSWORD"
    JENKINS_PORT=$(python3 -c "import yaml; print(yaml.safe_load(open('${REPO_ROOT}/central_deploy/roles/jenkins/defaults/main.yml'))['jenkins_http_port'])")
    JENKINS_URL="http://${PUBLIC_IP}:${JENKINS_PORT}"
    DUMMY_JOB="swiftacular-dummy"

    register_gerrit_trigger "$DUMMY_JOB"
    push_real_gerrit_patchset "$DUMMY_JOB" "$CENTRAL_GERRIT_USERNAME" "$CENTRAL_GERRIT_KEY_FILE" \
        "$CENTRAL_GERRIT_EMAIL" "$CENTRAL_DUMMY_CHANGE_NUMBER" "$REGISTER_BUILD"
    local build_number="$NUM"

    # jobs/swiftacular-dummy/Jenkinsfile pauses at an Approval stage before
    # the Dummy stage runs — same login-based check every identity goes
    # through, central included.
    wait_for_pending_input "$DUMMY_JOB" "$build_number" || exit 1
    local input_id="$INPUT_ID"

    echo "→ Approving as ${CENTRAL_GERRIT_USERNAME}..."
    submit_input_as "$DUMMY_JOB" "$build_number" "$input_id" "$CENTRAL_GERRIT_USERNAME" "$ADMIN_PASS" \
        || { echo "✗ ${CENTRAL_GERRIT_USERNAME} could not approve their own build (HTTP ${SUBMIT_HTTP_CODE})"; exit 1; }
    sleep 2
    confirm_input_cleared "$DUMMY_JOB" "$build_number" \
        || { echo "✗ Approval as ${CENTRAL_GERRIT_USERNAME} did not clear the pending input — Approval stage never proceeded"; exit 1; }
    echo "  (approval confirmed — pending input cleared)"

    wait_for_build_finish "$DUMMY_JOB" "$build_number"
    report_build_result "$DUMMY_JOB" "$build_number"
}

main() {
    parse_args "$@"
    require_root
    install_prereqs

    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT

    run_deploy
    verify_deploy
    print_final_status "✓ Central Jenkins installed and Gerrit trigger verified end-to-end."
}

main "$@"
