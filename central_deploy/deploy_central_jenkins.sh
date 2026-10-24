#!/usr/bin/env bash
# Installs central Jenkins + the dummy job + Gerrit wiring — the actual
# disaster-recovery tool. Usage: sudo ./deploy_central_jenkins.sh
# <path-to-gerrit_central.yml>. Always verifies via a real Gerrit push.
#
# The ONE install path: run as-is on a real machine for disaster recovery,
# and run.sh runs this same script, same command, same config shape inside
# its jenkins-01 VM for CI. Anything machine-specific belongs in here (or
# in the role), never in run.sh — otherwise CI stops testing what DR does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "${REPO_ROOT}/deploy_verify.sh"

# Broken proxy env — see run_common.sh for why. Strip it.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

parse_args() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: sudo ./deploy_central_jenkins.sh <path-to-gerrit_central.yml>" >&2
        exit 1
    fi
    ACCOUNTS_FILE="$1"
    [[ -f "$ACCOUNTS_FILE" ]] || { echo "✗ Not found: $ACCOUNTS_FILE" >&2; exit 1; }
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "✗ Must run as root (installs packages, systemd units): sudo $0 ${ACCOUNTS_FILE}" >&2
        exit 1
    fi
}

# A disaster-recovery script can't assume the target machine has anything
# beyond a base OS — install whatever's missing rather than failing.
# Supported: dnf (CentOS Stream / RHEL / Rocky / Fedora) and apt (Ubuntu
# 22.04). The Ansible role handles the same two.
install_prereqs() {
    local pm
    if command -v dnf >/dev/null 2>&1; then
        pm=dnf
    elif command -v apt-get >/dev/null 2>&1; then
        pm=apt
    else
        echo "✗ Unsupported OS: needs dnf (CentOS/RHEL/Fedora) or apt (Ubuntu)" >&2
        exit 1
    fi

    # Command -> package; only the YAML module's package name differs.
    declare -A pkg_for_cmd=( [ansible-playbook]=ansible [python3]=python3 [curl]=curl [git]=git [openssl]=openssl )
    local missing_pkgs=()
    local cmd
    for cmd in ansible-playbook python3 curl git openssl; do
        command -v "$cmd" >/dev/null 2>&1 || missing_pkgs+=("${pkg_for_cmd[$cmd]}")
    done
    # deploy_verify.sh parses the config with python3's yaml module.
    if ! python3 -c 'import yaml' >/dev/null 2>&1; then
        if [[ "$pm" == dnf ]]; then missing_pkgs+=(python3-pyyaml); else missing_pkgs+=(python3-yaml); fi
    fi

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        echo "→ Installing missing prerequisites: ${missing_pkgs[*]}..."
        if [[ "$pm" == dnf ]]; then
            # ansible isn't in CentOS Stream's base/AppStream repos — needs
            # EPEL first. Not needed on Fedora, already in its base repos.
            if [[ "${missing_pkgs[*]}" =~ (^|[[:space:]])ansible($|[[:space:]]) ]] \
                && [[ "$(. /etc/os-release && echo "$ID")" != "fedora" ]] \
                && ! dnf list installed epel-release >/dev/null 2>&1; then
                echo "→ Installing EPEL (required for the ansible package)..."
                dnf install -y epel-release
            fi
            dnf install -y "${missing_pkgs[@]}"
        else
            DEBIAN_FRONTEND=noninteractive apt-get update -q
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing_pkgs[@]}"
        fi
    fi

    # The distro `ansible` packages bundle community.general (the role's
    # alternatives module); a bare ansible-core install doesn't. Catch that
    # here with a fix, not mid-playbook.
    if ! ansible-doc -t module community.general.alternatives >/dev/null 2>&1; then
        echo "✗ Ansible collection community.general is missing (ansible-core alone doesn't ship it)." >&2
        echo "  Install it: ansible-galaxy collection install community.general" >&2
        exit 1
    fi
}

# Where a self-signed certificate goes when the config names none.
# Distro-neutral on purpose (not /etc/pki or /etc/ssl) — same path on every
# supported OS. run_common.sh fetches the .crt from here for the agent VMs.
GENERATED_TLS_DIR="/etc/jenkins-dr/tls"

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

# Uses the certificate the config names, or — when it names none — a
# self-signed one for PUBLIC_IP under GENERATED_TLS_DIR. Made once and
# reused across re-runs while it still matches PUBLIC_IP and isn't about to
# expire, so agents that already trust it keep working. Sets
# TLS_CERT_FILE / TLS_KEY_FILE / TLS_SELF_SIGNED.
ensure_tls_cert() {
    if [[ -n "$CENTRAL_TLS_CERT_FILE" ]]; then
        TLS_CERT_FILE="$CENTRAL_TLS_CERT_FILE"
        TLS_KEY_FILE="$CENTRAL_TLS_KEY_FILE"
        TLS_SELF_SIGNED=false
        return 0
    fi
    TLS_CERT_FILE="${GENERATED_TLS_DIR}/jenkins-dr.crt"
    TLS_KEY_FILE="${GENERATED_TLS_DIR}/jenkins-dr.key"
    TLS_SELF_SIGNED=true

    local check san
    if [[ "$PUBLIC_IP" =~ ^[0-9.]+$ ]]; then
        check=(-checkip "$PUBLIC_IP"); san="IP:${PUBLIC_IP}"
    else
        check=(-checkhost "$PUBLIC_IP"); san="DNS:${PUBLIC_IP}"
    fi
    if [[ -f "$TLS_CERT_FILE" && -f "$TLS_KEY_FILE" ]] \
        && openssl x509 -in "$TLS_CERT_FILE" -noout -checkend 86400 >/dev/null \
        && openssl x509 -in "$TLS_CERT_FILE" -noout "${check[@]}" | grep -q ' does match '; then
        echo "→ Reusing self-signed certificate ${TLS_CERT_FILE} (${san})"
        return 0
    fi

    echo "→ No tls_cert_file configured — creating a self-signed certificate for ${san}..."
    mkdir -p "$GENERATED_TLS_DIR"
    chmod 755 "$GENERATED_TLS_DIR"
    (umask 077 && openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=${PUBLIC_IP}" -addext "subjectAltName=${san}" \
        -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" 2>/dev/null)
    chmod 644 "$TLS_CERT_FILE"
}

run_deploy() {
    echo "→ Loading ${ACCOUNTS_FILE}..."
    load_central_account "$ACCOUNTS_FILE"
    validate_gerrit_account "central" "$CENTRAL_GERRIT_KEY_FILE" "$CENTRAL_GERRIT_USERNAME" "$CENTRAL_CHANGE_ID"

    if [[ -n "$CENTRAL_JENKINS_PUBLIC_IP" ]]; then
        PUBLIC_IP="$CENTRAL_JENKINS_PUBLIC_IP"
        echo "→ Using configured jenkins_public_ip: ${PUBLIC_IP}"
    else
        PUBLIC_IP=$(detect_public_ip)
        echo "→ Auto-detected IP: ${PUBLIC_IP} (set jenkins_public_ip in gerrit_central.yml to override)"
    fi
    ensure_tls_cert

    # JCasC still needs the raw PEM — hand it over as a real YAML file, not
    # inline -e key=value (the key's newlines would collide with Ansible's
    # whitespace-split parsing of multiple pairs in one -e). The resolved
    # TLS paths ride along, overriding the config's (possibly blank) ones.
    local key_vars_file="${WORKDIR}/gerrit_ssh_private_key.yml"
    python3 -c "import yaml,sys; yaml.safe_dump({'gerrit_ssh_private_key': open(sys.argv[1]).read(), 'tls_cert_file': sys.argv[3], 'tls_key_file': sys.argv[4]}, open(sys.argv[2], 'w'))" \
        "$CENTRAL_GERRIT_KEY_FILE" "$key_vars_file" "$TLS_CERT_FILE" "$TLS_KEY_FILE"

    local extra_vars=(-e "@${ACCOUNTS_FILE}" -e "@${key_vars_file}" -e "jenkins_public_ip=${PUBLIC_IP}" -e "dr_test_jenkinsfile_src=${REPO_ROOT}/jobs/jenkins-dr-test/Jenkinsfile")
    ansible-playbook -i "localhost," -c local -b \
        "${extra_vars[@]}" \
        "${REPO_ROOT}/central_deploy/deploy_jenkins.yml"
}

verify_deploy() {
    echo "→ Verifying: pushing a real Gerrit patchset and waiting for the dummy job to build..."
    ADMIN_USER="$CENTRAL_JENKINS_ADMIN_USER"
    ADMIN_PASS="$CENTRAL_JENKINS_ADMIN_PASSWORD"
    JENKINS_PORT=$(python3 -c "import yaml; print(yaml.safe_load(open('${REPO_ROOT}/central_deploy/roles/jenkins/defaults/main.yml'))['jenkins_http_port'])")
    # Straight to Jenkins on localhost, not through nginx — this script
    # runs on the server itself, and the role already checked nginx.
    JENKINS_URL="http://127.0.0.1:${JENKINS_PORT}"
    DUMMY_JOB="jenkins-dr-test"

    register_gerrit_trigger "$DUMMY_JOB"
    push_real_gerrit_patchset "$DUMMY_JOB" "$CENTRAL_GERRIT_USERNAME" "$CENTRAL_GERRIT_KEY_FILE" \
        "$CENTRAL_GERRIT_EMAIL" "$CENTRAL_GERRIT_DISPLAY_NAME" "$CENTRAL_CHANGE_ID" "$REGISTER_BUILD"
    local build_number="$NUM"

    # jobs/jenkins-dr-test/Jenkinsfile pauses at an Approval stage before
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
    # Root's own home, however sudo was invoked — `sudo` vs `sudo -H` and
    # distro defaults disagree on HOME, and load_central_account looks for
    # the Gerrit key under ~/.ssh. Always /root/.ssh, on every machine.
    HOME="$(getent passwd root | cut -d: -f6)"
    export HOME
    install_prereqs

    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT

    run_deploy
    verify_deploy
    JENKINS_URL="https://${PUBLIC_IP}"
    print_final_status "✓ Central Jenkins installed and Gerrit trigger verified end-to-end."
    if [[ "$TLS_SELF_SIGNED" == true ]]; then
        echo "  Self-signed certificate: ${TLS_CERT_FILE}"
        echo "  Give students a copy — it's their central_ca_cert (see student_deploy/CONNECT_AGENT.md)."
    fi
}

main "$@"
