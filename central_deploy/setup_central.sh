#!/usr/bin/env bash
# One command from a bare machine to a running central Jenkins — for
# disaster recovery, and what CI's run.sh runs inside its jenkins-01 VM.
#
#   sudo ./central_deploy/setup_central.sh <gerrit_central.yml> [--replace-old-jenkins] [--with-repo-jobs]
#
# Prepares the machine, then hands over to deploy_central_jenkins.sh:
#   1. prerequisites (Ansible, Python YAML, curl, git, openssl);
#   2. the GerritHub SSH key: created in /root/.ssh/<ssh_key_name> if
#      missing; if GerritHub doesn't accept it yet, registered via REST with
#      the config's gerrit_http_password. Never prompts — runs unattended;
#   3. with --replace-old-jenkins only (it stops processes and moves data):
#      retires an earlier hand-made Jenkins — whatever else holds
#      jenkins_internal_port, a distro `jenkins` service that isn't ours,
#      an old /var/lib/jenkins (moved aside, not deleted), and nginx
#      locations still proxying to that port. Anything this repo installed
#      carries a marker and is never touched;
#   4. opens jenkins_url's port in ufw / firewalld, if one is active;
#   5. deploy_central_jenkins.sh — install, configure, verify; with
#      --with-repo-jobs also runs, before Jenkins (re)starts, the
#      1_install_prereqs.sh of every job's main repo (the one its Gerrit
#      trigger watches), so the built-in node can build them;
#   6. with --with-repo-jobs (disaster recovery only — CI never passes it):
#      create_repo_jobs.sh — one pipeline job per jobs/<name>/Jenkinsfile.
# Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "${REPO_ROOT}/deploy_verify.sh"
source "${SCRIPT_DIR}/central_lib.sh"

unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

JENKINS_HOME_DIR="/var/lib/jenkins"

usage() {
    echo "Usage: sudo $0 <path-to-gerrit_central.yml> [--replace-old-jenkins] [--with-repo-jobs]" >&2
    exit 1
}

parse_args() {
    ACCOUNTS_FILE=""
    REPLACE_OLD=false
    REPO_JOBS=false
    local arg
    for arg in "$@"; do
        case "$arg" in
            --replace-old-jenkins) REPLACE_OLD=true ;;
            --with-repo-jobs) REPO_JOBS=true ;;
            -*) usage ;;
            *) [[ -z "$ACCOUNTS_FILE" ]] || usage; ACCOUNTS_FILE="$arg" ;;
        esac
    done
    [[ -n "$ACCOUNTS_FILE" ]] || usage
    [[ -f "$ACCOUNTS_FILE" ]] || { echo "✗ Not found: $ACCOUNTS_FILE" >&2; exit 1; }
    ACCOUNTS_FILE="$(realpath "$ACCOUNTS_FILE")"
}

title() {
    echo ""
    echo "── $1"
}

# Step 2a. Creates /root/.ssh/<ssh_key_name> if it doesn't exist yet.
# Reads just the fields it needs — load_central_account (which insists the
# key already exists) runs once it does.
ensure_gerrit_key() {
    title "GerritHub SSH key"
    local fields
    fields=$(python3 - "$ACCOUNTS_FILE" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(d.get('gerrit_username') or '')
print(d.get('ssh_key_name') or '')
PYEOF
    )
    GERRIT_USERNAME=$(sed -n 1p <<< "$fields")
    KEY_NAME=$(sed -n 2p <<< "$fields")
    [[ -n "$GERRIT_USERNAME" && -n "$KEY_NAME" ]] \
        || { echo "✗ ${ACCOUNTS_FILE}: gerrit_username and ssh_key_name are required" >&2; exit 1; }
    [[ "$KEY_NAME" =~ ^[A-Za-z0-9._-]+$ ]] \
        || { echo "✗ ssh_key_name must be a plain file name, got '${KEY_NAME}'" >&2; exit 1; }

    KEY_FILE="${HOME}/.ssh/${KEY_NAME}"
    if [[ -f "$KEY_FILE" ]]; then
        echo "→ Using existing key ${KEY_FILE}"
    else
        echo "→ Creating ${KEY_FILE}"
        mkdir -p "${HOME}/.ssh"
        chmod 700 "${HOME}/.ssh"
        ssh-keygen -q -t ed25519 -N '' -f "$KEY_FILE" -C "jenkins@$(hostname)"
    fi
}

# Step 2b. Makes sure GerritHub accepts the key as GERRIT_USERNAME. If it
# doesn't yet, registers it via REST with gerrit_http_password from the
# config — never prompts. Already accepted (CI: register_central_key.sh
# registered it on the host before this runs), the password isn't needed.
ensure_gerrit_key_registered() {
    if _gerrit_ssh_identity_ok "$KEY_FILE" "$GERRIT_USERNAME"; then
        echo "  ✓ GerritHub accepts ${KEY_FILE} as ${GERRIT_USERNAME}"
        return 0
    fi

    local http_password
    http_password=$(python3 - "$ACCOUNTS_FILE" <<'PYEOF'
import sys, yaml
print((yaml.safe_load(open(sys.argv[1])) or {}).get('gerrit_http_password') or '')
PYEOF
    )
    if [[ -z "$http_password" ]]; then
        echo "✗ GerritHub doesn't accept ${KEY_FILE} as ${GERRIT_USERNAME}, and gerrit_http_password" >&2
        echo "  is blank in ${ACCOUNTS_FILE}. Set it to ${GERRIT_USERNAME}'s GerritHub HTTP password" >&2
        echo "  (Settings > HTTP Credentials) and re-run — or add this public key by hand at" >&2
        echo "  https://review.gerrithub.io/settings/#SSHKeys and re-run:" >&2
        sed 's/^/    /' "${KEY_FILE}.pub" >&2
        exit 1
    fi

    echo "→ Registering ${KEY_FILE}.pub on GerritHub as ${GERRIT_USERNAME}..."
    # shellcheck source=../scripts/sudo/gerrit_key_lib.sh
    source "${REPO_ROOT}/scripts/sudo/gerrit_key_lib.sh"
    local key_seq resp
    resp=$(mktemp)
    key_seq=$(register_ssh_key "$GERRIT_USERNAME" "$http_password" "${KEY_FILE}.pub" "$resp") \
        || { rm -f "$resp"; echo "✗ Registration failed — is gerrit_http_password ${GERRIT_USERNAME}'s HTTP password (not the login password)?" >&2; exit 1; }
    rm -f "$resp"
    http_password=""
    echo "→ Registered (seq ${key_seq})"

    local i
    for i in $(seq 1 10); do
        if _gerrit_ssh_identity_ok "$KEY_FILE" "$GERRIT_USERNAME"; then
            echo "  ✓ GerritHub accepts ${KEY_FILE} as ${GERRIT_USERNAME}"
            return 0
        fi
        sleep 3
    done
    echo "✗ Registered, but GerritHub still doesn't accept the key as ${GERRIT_USERNAME} — check the account, then re-run." >&2
    exit 1
}

# Step 3. Only with --replace-old-jenkins. Each part is a no-op when
# there's nothing old, so a fresh machine (or CI's VM) passes straight
# through.
retire_old_jenkins() {
    title "Retiring an earlier hand-made Jenkins (--replace-old-jenkins)"

    # a. Whatever else holds Jenkins' internal port. A `daemon` supervisor
    #    parent goes first, so it can't restart the child.
    local pid parent
    for pid in $(foreign_port_holders); do
        echo "→ Stopping the process on port ${JENKINS_INTERNAL_PORT}:"
        ps -o pid=,user=,args= -p "$pid" | cut -c1-200 | sed 's/^/    /'
        parent=$(ps -o ppid= -p "$pid" | tr -d ' ')
        if [[ -n "$parent" && "$parent" != 1 && "$(ps -o comm= -p "$parent")" == daemon ]]; then
            kill "$parent" 2>/dev/null || true
        fi
        kill "$pid" 2>/dev/null || true
    done
    local i
    for i in $(seq 1 15); do
        [[ -z "$(foreign_port_holders)" ]] && break
        sleep 1
    done
    for pid in $(foreign_port_holders); do
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 1
    [[ -z "$(foreign_port_holders)" ]] \
        || { echo "✗ Port ${JENKINS_INTERNAL_PORT} is still held — stop that process by hand, then re-run." >&2; exit 1; }

    # b. A distro `jenkins` service (apt/yum package, init.d script) would
    #    fight ours over the name — ours carries MANAGED_UNIT_MARKER.
    if systemctl cat jenkins >/dev/null 2>&1 \
        && ! systemctl cat jenkins 2>/dev/null | grep -qF "$MANAGED_UNIT_MARKER"; then
        echo "→ Disabling the existing (non-central_deploy) jenkins service"
        systemctl disable --now jenkins 2>/dev/null || true
    fi

    # c. An old Jenkins home: moved aside (old jobs stay there), never
    #    deleted. Ours carries MANAGED_HOME_MARKER_FILE.
    if [[ -d "$JENKINS_HOME_DIR" && ! -f "${JENKINS_HOME_DIR}/${MANAGED_HOME_MARKER_FILE}" ]] \
        && [[ -n "$(ls -A "$JENKINS_HOME_DIR")" ]]; then
        local dest
        dest="${JENKINS_HOME_DIR}.old-$(date +%Y%m%d-%H%M%S)"
        echo "→ Moving the old ${JENKINS_HOME_DIR} aside to ${dest}"
        mv "$JENKINS_HOME_DIR" "$dest"
    fi

    # d. nginx locations elsewhere still proxying to the port.
    if [[ -d /etc/nginx ]]; then
        python3 "${SCRIPT_DIR}/nginx_jenkins_proxies.py" --port "$JENKINS_INTERNAL_PORT" --apply
    fi
}

# Step 4. The host firewall only — a cloud/network firewall in front of
# the machine still has to allow the port separately.
open_firewall() {
    title "Firewall (port ${JENKINS_LISTEN_PORT}/tcp)"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "${JENKINS_LISTEN_PORT}/tcp"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${JENKINS_LISTEN_PORT}/tcp"
        firewall-cmd --reload
    else
        echo "→ No active ufw/firewalld — nothing to open"
    fi
}

main() {
    parse_args "$@"
    if [[ "$EUID" -ne 0 ]]; then
        echo "✗ Must run as root: sudo $0 $*" >&2
        exit 1
    fi
    # Same as deploy_central_jenkins.sh: the key always lives in /root/.ssh.
    HOME="$(getent passwd root | cut -d: -f6)"
    export HOME

    title "Prerequisites"
    install_prereqs

    ensure_gerrit_key
    ensure_gerrit_key_registered

    # Full validation now that the key exists; also resolves the ports.
    load_central_account "$ACCOUNTS_FILE"
    resolve_jenkins_url

    if [[ "$REPLACE_OLD" == true ]]; then
        retire_old_jenkins
    fi
    open_firewall

    title "Install and verify (deploy_central_jenkins.sh)"
    if [[ "$REPO_JOBS" == true ]]; then
        "${SCRIPT_DIR}/deploy_central_jenkins.sh" "$ACCOUNTS_FILE" --with-repo-jobs
    else
        "${SCRIPT_DIR}/deploy_central_jenkins.sh" "$ACCOUNTS_FILE"
    fi

    if [[ "$REPO_JOBS" == true ]]; then
        title "Jobs from this repo (create_repo_jobs.sh)"
        "${SCRIPT_DIR}/create_repo_jobs.sh" "$ACCOUNTS_FILE"
    fi
}

main "$@"
