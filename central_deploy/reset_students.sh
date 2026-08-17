#!/usr/bin/env bash
# Tears down students on the central Jenkins, listed straight from Jenkins
# (no roster file needed). Usage: ./reset_students.sh [<name>... | all] —
# no arguments: asks which to delete. Asks for the Jenkins URL and admin
# login (see jenkins_connection.sh for the CI form).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/jenkins_connection.sh"

# Broken proxy env — see run_common.sh for why. Strip it.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

# Every provisioned student has exactly one agent node, "<name>-vm" — ask
# Jenkins for those directly rather than trusting any file.
list_provisioned_students() {
    local computers
    # -g: without it curl reads the tree=...[...] brackets as a URL glob
    # and refuses the request outright.
    computers=$(curl -sfg -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/computer/api/json?tree=computer[displayName]") || return 1
    python3 -c "
import sys, json
for c in json.load(sys.stdin)['computer']:
    if c['displayName'].endswith('-vm'):
        print(c['displayName'][:-len('-vm')])
" <<< "$computers"
}

delete_resource() {
    local url="$1" label="$2"
    local crumb http
    crumb=$(get_crumb)
    http=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "$crumb" -X POST "$url")
    case "$http" in
        200|302) echo "  ✓ deleted ${label}" ;;
        404)     echo "  ⚠ ${label} not found, skipping" ;;
        *)       err "could not delete ${label} — HTTP ${http}"; DELETE_FAILED=1 ;;
    esac
}

deprovision_student() {
    local name="$1"
    local node_name="${name}-vm"
    echo ""
    echo "  ${name}:"
    delete_resource "${JENKINS_URL}/computer/${node_name}/doDelete"     "node ${node_name}"
    delete_resource "${JENKINS_URL}/securityRealm/user/${name}/doDelete" "user ${name}"
}

main() {
    load_jenkins_connection

    local listing names=()
    listing=$(list_provisioned_students) \
        || { err "cannot list students on ${JENKINS_URL} as '${JENKINS_USER}' — check the URL, admin user and admin password"; exit 1; }
    [[ -n "$listing" ]] && mapfile -t names <<< "$listing"

    if [[ ${#names[@]} -eq 0 ]]; then
        echo "No students currently provisioned."
    else
        echo "Currently provisioned students:"
        printf '  %s\n' "${names[@]}"
    fi
    echo ""

    local selected=("$@")
    if [[ ${#selected[@]} -eq 0 ]]; then
        [[ ${#names[@]} -eq 0 ]] && exit 0
        local answer=""
        read -rp "Delete which? (names, space-separated, 'all', or blank to cancel): " answer || true
        [[ -z "$answer" ]] && { echo "Cancelled."; exit 0; }
        read -ra selected <<< "$answer"
    fi
    [[ "${selected[*]}" == "all" ]] && selected=("${names[@]}")

    # Only ever delete what Jenkins listed above — a typo must not remove
    # some other Jenkins account that happens to have that name.
    local name
    for name in "${selected[@]}"; do
        [[ " ${names[*]} " == *" ${name} "* ]] \
            || { err "'${name}' is not a provisioned student — nothing deleted"; exit 1; }
    done
    [[ ${#selected[@]} -eq 0 ]] && exit 0

    COOKIE_JAR=$(mktemp)
    trap 'rm -f "$COOKIE_JAR"' EXIT
    DELETE_FAILED=0

    echo "── Tearing down selected student resources ──────────────────"
    for name in "${selected[@]}"; do deprovision_student "$name"; done
    [[ "$DELETE_FAILED" -eq 0 ]] || exit 1
}

main "$@"
