#!/usr/bin/env bash
# Installs central Jenkins + the dummy job + Gerrit wiring. Normally run
# via setup_central.sh (which prepares the machine first); runnable on its
# own on an already-prepared one. Usage: sudo ./deploy_central_jenkins.sh
# <path-to-gerrit_central.yml>. Always verifies the Gerrit Trigger plugin
# is connected to GerritHub; with email/display_name/change_id set (as CI
# sets them) also verifies end-to-end via a real Gerrit push.
#
# The ONE install path: setup_central.sh -> this script, on a real machine
# for disaster recovery, and run.sh runs the same command with the same
# config shape inside its jenkins-01 VM for CI. Anything machine-specific belongs in here (or
# in the role), never in run.sh — otherwise CI stops testing what DR does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "${REPO_ROOT}/deploy_verify.sh"
source "${SCRIPT_DIR}/central_lib.sh"

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

# Where a self-signed certificate goes when the config names none.
# Distro-neutral on purpose (not /etc/pki or /etc/ssl) — same path on every
# supported OS. run_common.sh fetches the .crt from here for the agent VMs.
GENERATED_TLS_DIR="/etc/jenkins-dr/tls"
# Where a generated admin password is kept when the config sets none —
# root-only, and reused on re-runs so the login never silently changes.
GENERATED_ADMIN_PASSWORD_FILE="/etc/jenkins-dr/admin_password"
# Must match the gerrit-trigger server name in jenkins.yaml.j2.
GERRIT_SERVER_NAME="review.gerrithub.io"

# Leftovers from an earlier hand-made Jenkins on this machine, checked
# before anything is installed:
# - something other than the jenkins systemd service holding
#   jenkins_internal_port (an old Jenkins started by hand, or nginx itself) —
#   Jenkins would just fail to start;
# - an nginx location elsewhere still proxying to that port — it would keep
#   serving the new Jenkins on its old listener, bypassing this HTTPS site.
#   nginx_jenkins_proxies.py reports them, and removes them with --apply.
preflight_host() {
    local pid
    for pid in $(foreign_port_holders); do
        echo "✗ Port ${JENKINS_INTERNAL_PORT} (jenkins_internal_port) is already taken by another process:" >&2
        ps -o pid=,user=,args= -p "$pid" | cut -c1-200 | sed 's/^/    /' >&2
        echo "  An old Jenkins? setup_central.sh --replace-old-jenkins stops it; or pick a free jenkins_internal_port." >&2
        exit 1
    done

    local rc=0
    python3 "${SCRIPT_DIR}/nginx_jenkins_proxies.py" --port "$JENKINS_INTERNAL_PORT" || rc=$?
    [[ "$rc" -eq 0 ]] || exit 1

    # jenkins_url's port vs. nginx servers already on it: a separate
    # Jenkins server must not take over other apps' port; shared mode needs
    # exactly one server to attach to.
    if [[ -d /etc/nginx ]]; then
        local mode=standalone
        [[ "$CENTRAL_NGINX_SHARED_SERVER" == true ]] && mode=shared
        python3 "${SCRIPT_DIR}/nginx_shared_server.py" check --port "$JENKINS_LISTEN_PORT" --mode "$mode" || exit 1
    elif [[ "$CENTRAL_NGINX_SHARED_SERVER" == true ]]; then
        echo "✗ nginx_shared_server: true, but nginx isn't installed — there's no server to attach to" >&2
        exit 1
    fi
}

# For https only: uses the certificate the config names, or — when it
# names none — a self-signed one for JENKINS_HOST under GENERATED_TLS_DIR.
# Made once and reused across re-runs while it still matches JENKINS_HOST
# and isn't about to expire, so agents that already trust it keep working.
# Sets TLS_CERT_FILE / TLS_KEY_FILE / TLS_SELF_SIGNED.
ensure_tls_cert() {
    TLS_CERT_FILE=""
    TLS_KEY_FILE=""
    TLS_SELF_SIGNED=false
    if [[ "$JENKINS_SCHEME" != https ]]; then
        return 0
    fi
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
    if [[ "$JENKINS_HOST" =~ ^[0-9.]+$ ]]; then
        check=(-checkip "$JENKINS_HOST"); san="IP:${JENKINS_HOST}"
    else
        check=(-checkhost "$JENKINS_HOST"); san="DNS:${JENKINS_HOST}"
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
        -subj "/CN=${JENKINS_HOST}" -addext "subjectAltName=${san}" \
        -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" 2>/dev/null)
    chmod 644 "$TLS_CERT_FILE"
}

# Uses the config's jenkins_admin_password, or — when blank — one generated
# once into GENERATED_ADMIN_PASSWORD_FILE. Sets CENTRAL_JENKINS_ADMIN_PASSWORD
# and ADMIN_PASSWORD_GENERATED.
ensure_admin_password() {
    if [[ -n "$CENTRAL_JENKINS_ADMIN_PASSWORD" ]]; then
        ADMIN_PASSWORD_GENERATED=false
        return 0
    fi
    ADMIN_PASSWORD_GENERATED=true
    if [[ ! -s "$GENERATED_ADMIN_PASSWORD_FILE" ]]; then
        echo "→ No jenkins_admin_password configured — generating one into ${GENERATED_ADMIN_PASSWORD_FILE}"
        mkdir -p "$(dirname "$GENERATED_ADMIN_PASSWORD_FILE")"
        (umask 077 && openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24 > "$GENERATED_ADMIN_PASSWORD_FILE")
    fi
    chmod 600 "$GENERATED_ADMIN_PASSWORD_FILE"
    CENTRAL_JENKINS_ADMIN_PASSWORD="$(cat "$GENERATED_ADMIN_PASSWORD_FILE")"
}

run_deploy() {
    echo "→ Loading ${ACCOUNTS_FILE}..."
    load_central_account "$ACCOUNTS_FILE"
    validate_gerrit_account "central" "$CENTRAL_GERRIT_KEY_FILE" "$CENTRAL_GERRIT_USERNAME" "$CENTRAL_CHANGE_ID"

    resolve_jenkins_url
    preflight_host
    ensure_tls_cert
    ensure_admin_password

    # JCasC still needs the raw PEM — hand it over as a real YAML file, not
    # inline -e key=value (the key's newlines would collide with Ansible's
    # whitespace-split parsing of multiple pairs in one -e). The resolved
    # TLS paths, admin password and resolved URL parts ride along,
    # overriding the config's (possibly blank) ones — and keep the password
    # off any command line.
    local key_vars_file="${WORKDIR}/gerrit_ssh_private_key.yml"
    CENTRAL_JENKINS_ADMIN_PASSWORD="$CENTRAL_JENKINS_ADMIN_PASSWORD" python3 - "$key_vars_file" \
        "$CENTRAL_GERRIT_KEY_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE" \
        "$JENKINS_EXT_URL" "$JENKINS_SCHEME" "$JENKINS_HOST" "$JENKINS_PREFIX" "$JENKINS_LISTEN_PORT" \
        "$JENKINS_INTERNAL_PORT" "$CENTRAL_NGINX_SHARED_SERVER" <<'PYEOF'
import os, sys, yaml
dst, key_file, cert, key, url, scheme, host, prefix, listen_port, internal_port, shared = sys.argv[1:12]
yaml.safe_dump({
    'gerrit_ssh_private_key': open(key_file).read(),
    'tls_cert_file': cert,
    'tls_key_file': key,
    'jenkins_admin_password': os.environ['CENTRAL_JENKINS_ADMIN_PASSWORD'],
    'jenkins_url': url,
    'jenkins_scheme': scheme,
    'jenkins_host': host,
    'jenkins_prefix': prefix,
    'jenkins_listen_port': int(listen_port),
    'jenkins_internal_port': int(internal_port),
    'nginx_shared_server': shared == 'true',
}, open(dst, 'w'))
PYEOF

    local extra_vars=(-e "@${ACCOUNTS_FILE}" -e "@${key_vars_file}" -e "dr_test_jenkinsfile_src=${REPO_ROOT}/jobs/jenkins-dr-test/Jenkinsfile")
    ansible-playbook -i "localhost," -c local -b \
        "${extra_vars[@]}" \
        "${REPO_ROOT}/central_deploy/deploy_jenkins.yml"
}

# The one thing a DR Jenkins needs from Gerrit: the Gerrit Trigger plugin
# holding its stream-events connection, so pushes trigger jobs. Asks the
# plugin itself (script console, as admin) rather than inferring it.
wait_for_gerrit_connected() {
    echo "→ Waiting for the Gerrit Trigger plugin to connect to ${GERRIT_SERVER_NAME} as ${CENTRAL_GERRIT_USERNAME}..."
    local script="println(com.sonyericsson.hudson.plugins.gerrit.trigger.PluginImpl.getInstance().getServer('${GERRIT_SERVER_NAME}').isConnected())"
    local i crumb out=""
    for i in $(seq 1 30); do
        if crumb=$(get_crumb 2>/dev/null); then
            out=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -c "${WORKDIR}/cookies" -b "${WORKDIR}/cookies" \
                -H "$crumb" --data-urlencode "script=${script}" "${JENKINS_URL}/scriptText" 2>/dev/null || true)
            if [[ "$(echo "$out" | tr -d '[:space:]')" == "true" ]]; then
                echo "  ✓ Gerrit Trigger connected — Gerrit events will trigger jobs"
                return 0
            fi
        fi
        sleep 2
    done
    echo "✗ Gerrit Trigger never connected to ${GERRIT_SERVER_NAME} (last answer: '${out}')." >&2
    echo "  SSH auth as ${CENTRAL_GERRIT_USERNAME} passed the preflight, so check the plugin's" >&2
    echo "  status in Manage Jenkins > Gerrit Trigger, and: journalctl -u jenkins" >&2
    exit 1
}

verify_deploy() {
    ADMIN_USER="$CENTRAL_JENKINS_ADMIN_USER"
    ADMIN_PASS="$CENTRAL_JENKINS_ADMIN_PASSWORD"
    # Straight to Jenkins on localhost, not through nginx — this script
    # runs on the server itself, and the role already checked nginx.
    JENKINS_URL="http://127.0.0.1:${JENKINS_INTERNAL_PORT}${JENKINS_PREFIX}"
    DUMMY_JOB="jenkins-dr-test"

    wait_for_gerrit_connected

    if [[ "$CENTRAL_VERIFY_PUSH" != true ]]; then
        echo "→ email/display_name/change_id not set — skipping the end-to-end Gerrit push test."
        return 0
    fi

    echo "→ Verifying: pushing a real Gerrit patchset and waiting for the dummy job to build..."
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
    JENKINS_URL="${JENKINS_EXT_URL}/"
    if [[ "$CENTRAL_VERIFY_PUSH" == true ]]; then
        print_final_status "✓ Central Jenkins installed and Gerrit trigger verified end-to-end."
    else
        print_final_status "✓ Central Jenkins installed and connected to GerritHub."
    fi
    if [[ "$ADMIN_PASSWORD_GENERATED" == true ]]; then
        echo "  Admin password: sudo cat ${GENERATED_ADMIN_PASSWORD_FILE}"
    fi
    if [[ "$JENKINS_SCHEME" == http ]]; then
        echo "  ⚠ Plain HTTP: logins, API tokens and agent secrets cross the network unencrypted."
    fi
    if [[ "$TLS_SELF_SIGNED" == true ]]; then
        echo "  Self-signed certificate: ${TLS_CERT_FILE}"
        echo "  Give students a copy — it's their central_ca_cert (see student_deploy/CONNECT_AGENT.md)."
    fi
}

main "$@"
