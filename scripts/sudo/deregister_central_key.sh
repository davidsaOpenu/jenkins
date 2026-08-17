#!/usr/bin/env bash
#
# deregister_central_key.sh
#
# Deregisters central Jenkins' Gerrit Trigger SSH key from jenkins-osw's
# GerritHub account and clears the state file register_central_key.sh
# wrote. Safe to call repeatedly / on a leftover run — a missing or empty
# state file is a silent no-op, not an error.
#
# DEPLOYMENT: installed by deploy_gerrit_multi_user_push.sh, alongside
# the other /opt/ci scripts. Runs as root via the zero-arg sudoers rule:
#   jenkins ALL=(root) NOPASSWD: /opt/ci/deregister_central_key.sh ""
#
# Called from cleanup.sh (both clean_start and the final teardown), and
# safe to call even if register_central_key.sh was never run this cycle.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: this script must be run as root (via sudo), not as $(id -un)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/opt/ci/gerrit_key_lib.sh
source "${SCRIPT_DIR}/gerrit_key_lib.sh"
# shellcheck source=/opt/ci/gerrit_users.sh
source "${SCRIPT_DIR}/gerrit_users.sh"

STATE_FILE="/opt/ci/state/central_key_seq"

if [[ ! -s "${STATE_FILE}" ]]; then
  echo "No central key state file — nothing to deregister."
  exit 0
fi

SECRETS_FILE="/opt/ci/secrets/gerrit_tokens.env"
if [[ ! -f "${SECRETS_FILE}" ]]; then
  echo "ERROR: secrets file not found: ${SECRETS_FILE}" >&2
  exit 1
fi

secrets_perms="$(stat -c '%a' "${SECRETS_FILE}")"
secrets_owner="$(stat -c '%U:%G' "${SECRETS_FILE}")"
if [[ "${secrets_perms}" != "600" || "${secrets_owner}" != "root:root" ]]; then
  echo "ERROR: refusing to load ${SECRETS_FILE} — expected mode 600, owner root:root," >&2
  echo "       found mode ${secrets_perms}, owner ${secrets_owner}." >&2
  exit 1
fi

# shellcheck source=/opt/ci/secrets/gerrit_tokens.env
source "${SECRETS_FILE}"

IFS='|' read -r GERRIT_USER _KEY_NAME _EMAIL _DISPLAY_NAME _CHANGE_ID <<< "${USERS[0]}"
TOKEN_VAR="$(token_var_for "${GERRIT_USER}")"
TOKEN="${!TOKEN_VAR:-}"
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: ${TOKEN_VAR} is not set in ${SECRETS_FILE}" >&2
  exit 1
fi

SEQ="$(cat "${STATE_FILE}")"
deregister_ssh_key "${GERRIT_USER}" "${TOKEN}" "${SEQ}"
rm -f "${STATE_FILE}"
