#!/usr/bin/env bash
# Daily self-check: builds a fresh, fully-configured Jenkins from scratch and
# proves the Gerrit trigger wiring actually works. No vault, no real secrets
# anywhere — hardcoded admin password, a throwaway generated Gerrit SSH key
# that never actually connects to GerritHub, and a simulated Gerrit event.
# This is what cron and Gerrit-triggered runs use — no human present, nothing
# to expose.
#
# For a real production deploy (real vault creds, real GerritHub-registered
# SSH key, optionally pushing a real patchset), use run_real_gerrit.sh.
#
# --local-repo (testing only): serve this checkout over a local git daemon
# instead of pointing the dummy job at the real GerritHub master — lets you
# validate the trigger-registration/simulated-event steps before this code is
# ever pushed/merged.
#
# The VM is always left running after this script exits, success or failure —
# ready to inspect, or to SSH in and debug. Use cleanup.sh separately to tear
# it down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/run_common.sh"

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --local-repo) LOCAL_REPO=true ;;
        esac
    done
}

start_local_git_daemon() {
    echo "→ --local-repo: serving this checkout over a local git daemon..."
    sudo firewall-cmd --add-port=9418/tcp --zone=libvirt 2>/dev/null || true
    touch "${SCRIPT_DIR}/.git/git-daemon-export-ok"
    # pkill signals but doesn't wait for the port to free — poll first.
    pkill -f "git daemon.*${SCRIPT_DIR}" 2>/dev/null || true
    for _ in $(seq 1 20); do
        ss -tln 2>/dev/null | grep -q ':9418 ' || break
        sleep 0.5
    done
    git daemon --reuseaddr --base-path="$(dirname "$SCRIPT_DIR")" --export-all --port=9418 "$SCRIPT_DIR" &
    GIT_DAEMON_PID=$!
    echo "→ Serving at git://192.168.100.1/jenkins (PID ${GIT_DAEMON_PID})"
}

generate_selfcheck_credentials() {
    echo "→ Self-check mode: hardcoded admin password, throwaway Gerrit key, simulated event — no vault involved"
    ADMIN_PASS="admin1234"
    GERRIT_USER="selfcheck"
    rm -f "$TMP_GERRIT_KEY"
    ssh-keygen -q -t ed25519 -N "" -f "$TMP_GERRIT_KEY"

    # Extra-vars file, not -e key=value, because the key's PEM content is
    # multi-line — ansible-playbook still consumes it fine via -e "@file".
    TMP_EXTRA_VARS=$(mktemp)
    python3 - "$ADMIN_PASS" "$GERRIT_USER" "$TMP_GERRIT_KEY" "$TMP_EXTRA_VARS" <<'PYEOF'
import sys, yaml
admin_pass, gerrit_user, key_file, out_file = sys.argv[1:5]
yaml.safe_dump({
    'vault_in_use': False,
    'gerrit_connect_on_startup': False,
    'jenkins_admin_password': admin_pass,
    'gerrit_ssh_username': gerrit_user,
    'gerrit_ssh_private_key': open(key_file).read(),
}, open(out_file, 'w'))
PYEOF
    EXTRA_VARS+=(-e "@${TMP_EXTRA_VARS}")
}

# Self-check never opens a real connection to GerritHub (noConnectionOnStartup),
# so nothing else here would ever notice a firewall/DNS/GerritHub outage. This
# needs no credentials — just proves the network path is still open.
check_gerrithub_reachable() {
    echo "→ Checking network reachability to review.gerrithub.io:29418..."
    if nc -z -w5 review.gerrithub.io 29418; then
        echo "  ✓ reachable"
    else
        echo "✗ Cannot reach review.gerrithub.io:29418 — check firewall/DNS/GerritHub status"
        exit 1
    fi
}

main() {
    parse_args "$@"
    common_setup "$@"
    diagnose_jenkins_reachability

    spawn_vm
    build_inventory

    title "Step 4/8 — Credentials"
    VAULT_ARGS=()
    EXTRA_VARS=()
    [[ "$LOCAL_REPO" == "true" ]] && EXTRA_VARS+=(-e "dummy_job_repo_url=git://192.168.100.1/jenkins")
    generate_selfcheck_credentials
    chmod 600 "$TMP_GERRIT_KEY"
    fetch_jenkins_artifacts

    deploy_jenkins
    register_gerrit_trigger

    title "Step 7/8 — Simulate Gerrit event directly (no GerritHub)"
    check_gerrithub_reachable
    simulate_gerrit_event "$REGISTER_BUILD"

    report_build_result
    print_final_status "✓ Self-check passed — deploy automation and Gerrit trigger logic verified.
  (admin1234 / throwaway Gerrit key — not meant to serve as production)"
}

main "$@"
