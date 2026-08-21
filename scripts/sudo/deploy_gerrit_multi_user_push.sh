#!/usr/bin/env bash
#
# deploy_gerrit_multi_user_push.sh
#
# Installs gerrit_multi_user_push.sh into place, sets up its secrets
# file, and configures the sudoers rule that lets `jenkins` invoke it
# (as root, with zero arguments).
#
# USAGE:
#   Run this AS ROOT, from the SAME DIRECTORY that contains
#   gerrit_multi_user_push.sh:
#
#     cd /path/to/dir/containing/gerrit_multi_user_push.sh
#     sudo ./deploy_gerrit_multi_user_push.sh
#
# WHAT IT DOES (idempotent — safe to re-run):
#   1. Verifies it's run as root and that gerrit_multi_user_push.sh
#      exists in the current directory.
#   2. Creates /opt/ci/secrets (root:root, 0700).
#   3. Installs gerrit_multi_user_push.sh to
#      /opt/ci/gerrit_multi_user_push.sh (root:root, 0700).
#   4. Creates /opt/ci/secrets/gerrit_tokens.env from a template and
#      opens it in $EDITOR (or vi) IF it doesn't already exist — an
#      existing tokens file is never touched or overwritten.
#   5. Writes /etc/sudoers.d/gerrit-push, validated with `visudo -c`
#      BEFORE it's installed, so a syntax error can never corrupt the
#      live sudoers configuration.
#   6. Prints verification commands to confirm everything is wired up
#      correctly.
#
set -euo pipefail

SCRIPT_NAME="gerrit_multi_user_push.sh"
INSTALL_DIR="/opt/ci"
INSTALL_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
SECRETS_DIR="${INSTALL_DIR}/secrets"
SECRETS_FILE="${SECRETS_DIR}/gerrit_tokens.env"
SUDOERS_FILE="/etc/sudoers.d/gerrit-push"
SUDOERS_LINE="jenkins ALL=(root) NOPASSWD: ${INSTALL_PATH} \"\""

# ---------------------------------------------------------------------------
# 1. Preconditions
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run this as root, e.g.: sudo ./$(basename "$0")" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="${SCRIPT_DIR}/${SCRIPT_NAME}"

if [[ ! -f "${SOURCE_SCRIPT}" ]]; then
  echo "ERROR: ${SCRIPT_NAME} not found in ${SCRIPT_DIR}." >&2
  echo "       Run this deploy script from the same directory as ${SCRIPT_NAME}." >&2
  exit 1
fi

echo "==> Deploying from: ${SOURCE_SCRIPT}"

# ---------------------------------------------------------------------------
# 2 & 3. Install the script + create secrets dir
# ---------------------------------------------------------------------------
mkdir -p "${SECRETS_DIR}"
chown root:root "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"
echo "==> Secrets dir ready: ${SECRETS_DIR} (root:root, 700)"

install -o root -g root -m 700 "${SOURCE_SCRIPT}" "${INSTALL_PATH}"
echo "==> Installed: ${INSTALL_PATH} (root:root, 700)"

# ---------------------------------------------------------------------------
# 4. Secrets file — created once, never overwritten on re-run
# ---------------------------------------------------------------------------
if [[ -f "${SECRETS_FILE}" ]]; then
  echo "==> Secrets file already exists, leaving it untouched: ${SECRETS_FILE}"
else
  cat > "${SECRETS_FILE}" <<'EOF'
# gerrit_tokens.env
# HTTP tokens for each GerritHub service account used by
# gerrit_multi_user_push.sh. Each token only needs to manage that same
# account's own SSH keys (self-service REST scope) — never a shared
# admin credential.
JENKINS_OSW_TOKEN="REPLACE_ME"
JENKINS_USERA_TOKEN="REPLACE_ME"
JENKINS_USERB_TOKEN="REPLACE_ME"
EOF
  chown root:root "${SECRETS_FILE}"
  chmod 600 "${SECRETS_FILE}"
  echo "==> Created ${SECRETS_FILE} (root:root, 600) from template."
  echo "==> Opening it now — fill in the 3 real tokens and save."
  "${EDITOR:-vi}" "${SECRETS_FILE}"
fi

# ---------------------------------------------------------------------------
# 5. sudoers — validated before install, never written blind
# ---------------------------------------------------------------------------
TMP_SUDOERS="$(mktemp)"
trap 'rm -f "${TMP_SUDOERS}"' EXIT
echo "${SUDOERS_LINE}" > "${TMP_SUDOERS}"

if ! visudo -cf "${TMP_SUDOERS}"; then
  echo "ERROR: generated sudoers line failed validation — not installing it." >&2
  echo "       Line was: ${SUDOERS_LINE}" >&2
  exit 1
fi

install -o root -g root -m 440 "${TMP_SUDOERS}" "${SUDOERS_FILE}"
echo "==> Installed sudoers rule: ${SUDOERS_FILE}"
echo "       ${SUDOERS_LINE}"

# ---------------------------------------------------------------------------
# 6. Verification
# ---------------------------------------------------------------------------
echo
echo "==> Deployment complete. Verify with:"
echo "     sudo -u jenkins sudo ${INSTALL_PATH}              # should run normally"
echo "     sudo -u jenkins sudo ${INSTALL_PATH} anything      # must be REJECTED"
echo
echo "==> Reminder: if the secrets file already existed and still has"
echo "    REPLACE_ME placeholders, edit it now:"
echo "     ${EDITOR:-vi} ${SECRETS_FILE}"
