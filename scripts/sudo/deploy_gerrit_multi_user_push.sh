#!/bin/bash
#
# deploy_gerrit_multi_user_push.sh
#
# Installs gerrit_multi_user_push.sh, register_central_key.sh, and
# deregister_central_key.sh (plus their shared libs) into place, sets up
# the secrets file, and configures the sudoers rules that let `jenkins`
# invoke all 3 (as root, with zero arguments).
#
# USAGE:
#   Run this AS ROOT, from the SAME DIRECTORY that contains
#   gerrit_multi_user_push.sh:
#
#     cd /path/to/dir/containing/gerrit_multi_user_push.sh
#     sudo ./deploy_gerrit_multi_user_push.sh
#
# WHAT IT DOES (idempotent — safe to re-run):
#   1. Verifies it's run as root and that all source files exist
#      (4 in this directory, gerrit_users.sh one directory up), and that
#      `jenkins` can't write any of them or any directory above them —
#      otherwise jenkins could swap a script before it's installed as a
#      root-run, sudo-allowed binary. Run this from a fresh clone owned by
#      you or root, never from a Jenkins workspace, and diff the printed
#      checksums against the reviewed commit before continuing.
#   2. Forces /opt/ci to root:root 0755 (and refuses if jenkins can write
#      it or any parent), then creates /opt/ci/secrets and /opt/ci/state
#      (root:root, 0700).
#   3. Installs all 5 scripts to /opt/ci/ (root:root, 0700).
#   4. Creates /opt/ci/secrets/gerrit_tokens.env from a template and
#      opens it in $EDITOR (or vi) IF it doesn't already exist — an
#      existing tokens file is never touched or overwritten.
#   5. Writes /etc/sudoers.d/gerrit-push (3 zero-arg rules), validated
#      with `visudo -c` BEFORE it's installed, so a syntax error can
#      never corrupt the live sudoers configuration.
#   6. Prints verification commands to confirm everything is wired up
#      correctly.
#
set -euo pipefail

INSTALL_DIR="/opt/ci"
SECRETS_DIR="${INSTALL_DIR}/secrets"
SECRETS_FILE="${SECRETS_DIR}/gerrit_tokens.env"
STATE_DIR="${INSTALL_DIR}/state"
SUDOERS_FILE="/etc/sudoers.d/gerrit-push"

# Installed from this directory (root:root, 0700 — same boundary for all).
LOCAL_SCRIPTS=(
  gerrit_key_lib.sh
  gerrit_multi_user_push.sh
  register_central_key.sh
  deregister_central_key.sh
)
# gerrit_users.sh is the shared identity source of truth, also consumed
# by deploy_verify.sh/run.sh (unprivileged) from its repo location —
# this only installs a second, root-only copy for the /opt/ci scripts.
SHARED_USERS_SCRIPT="gerrit_users.sh"

ZERO_ARG_COMMANDS=(
  gerrit_multi_user_push.sh
  register_central_key.sh
  deregister_central_key.sh
)

# ---------------------------------------------------------------------------
# 1. Preconditions
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run this as root, e.g.: sudo ./$(basename "$0")" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERS_SOURCE="${SCRIPT_DIR}/../${SHARED_USERS_SCRIPT}"

for name in "${LOCAL_SCRIPTS[@]}"; do
  if [[ ! -f "${SCRIPT_DIR}/${name}" ]]; then
    echo "ERROR: ${name} not found in ${SCRIPT_DIR}." >&2
    echo "       Run this deploy script from the same directory as ${name}." >&2
    exit 1
  fi
done
if [[ ! -f "${USERS_SOURCE}" ]]; then
  echo "ERROR: ${SHARED_USERS_SCRIPT} not found at ${USERS_SOURCE}." >&2
  exit 1
fi

# Exits if jenkins can write $1 or any directory above it (write access
# to a directory = can rename/replace the entry). Resolved with realpath
# so a symlink can't hide the real location.
refuse_if_jenkins_writable() {
  id jenkins &>/dev/null || return 0
  local path
  path="$(realpath -e "$1")"
  while :; do
    if runuser -u jenkins -- test -w "${path}"; then
      echo "ERROR: ${path} is writable by jenkins — refusing to continue:" >&2
      echo "       jenkins could swap $1, which root runs via sudo." >&2
      echo "       Deploy from a clone jenkins can't modify (owned by you or" >&2
      echo "       root, not a workspace), and keep ${INSTALL_DIR}'s parents root-owned." >&2
      exit 1
    fi
    [[ "${path}" == "/" ]] && break
    path="$(dirname "${path}")"
  done
}

# Refuse any source jenkins could tamper with before root installs it.
for src in "${LOCAL_SCRIPTS[@]/#/${SCRIPT_DIR}/}" "${USERS_SOURCE}"; do
  refuse_if_jenkins_writable "${src}"
done

echo "==> Deploying from: ${SCRIPT_DIR}"
# Deliberately no git calls here: git run as root in a non-root-owned
# checkout can execute repo-configured commands (e.g. core.fsmonitor).
# Compare as yourself instead: git show <reviewed-commit>:<path> | sha256sum
echo "==> SHA-256 of files to install (compare against the reviewed commit):"
sha256sum "${LOCAL_SCRIPTS[@]/#/${SCRIPT_DIR}/}" "${USERS_SOURCE}" | sed 's/^/       /'

# ---------------------------------------------------------------------------
# 2 & 3. Create dirs + install all scripts
# ---------------------------------------------------------------------------
# sudo authorizes by path only, never by ownership — if jenkins could
# write INSTALL_DIR (or a parent), it could replace a sudo-allowed script.
mkdir -p "${INSTALL_DIR}"
chown root:root "${INSTALL_DIR}"
chmod 755 "${INSTALL_DIR}"
refuse_if_jenkins_writable "${INSTALL_DIR}"
echo "==> Install dir ready: ${INSTALL_DIR} (root:root, 755)"

mkdir -p "${SECRETS_DIR}"
chown root:root "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"
echo "==> Secrets dir ready: ${SECRETS_DIR} (root:root, 700)"

mkdir -p "${STATE_DIR}"
chown root:root "${STATE_DIR}"
chmod 700 "${STATE_DIR}"
echo "==> State dir ready: ${STATE_DIR} (root:root, 700)"

for name in "${LOCAL_SCRIPTS[@]}"; do
  install -o root -g root -m 700 "${SCRIPT_DIR}/${name}" "${INSTALL_DIR}/${name}"
  echo "==> Installed: ${INSTALL_DIR}/${name} (root:root, 700)"
done
install -o root -g root -m 700 "${USERS_SOURCE}" "${INSTALL_DIR}/${SHARED_USERS_SCRIPT}"
echo "==> Installed: ${INSTALL_DIR}/${SHARED_USERS_SCRIPT} (root:root, 700)"

# ---------------------------------------------------------------------------
# 4. Secrets file — created once, never overwritten on re-run
# ---------------------------------------------------------------------------
if [[ -f "${SECRETS_FILE}" ]]; then
  echo "==> Secrets file already exists, leaving it untouched: ${SECRETS_FILE}"
else
  # umask 077: the file is never readable by anyone but root, even
  # between creation and the explicit chmod below.
  (umask 077 && cat > "${SECRETS_FILE}") <<'EOF'
# gerrit_tokens.env
# HTTP tokens for each GerritHub service account used by
# gerrit_multi_user_push.sh / register_central_key.sh. These are FULL
# account credentials: a GerritHub HTTP password grants complete REST
# access as that account (voting, abandoning, account settings), not just
# SSH-key management. Use dedicated service accounts with minimal project
# permissions — never a personal or admin account.
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
for name in "${ZERO_ARG_COMMANDS[@]}"; do
  echo "jenkins ALL=(root) NOPASSWD: ${INSTALL_DIR}/${name} \"\"" >> "${TMP_SUDOERS}"
done

if ! visudo -cf "${TMP_SUDOERS}"; then
  echo "ERROR: generated sudoers rules failed validation — not installing them." >&2
  cat "${TMP_SUDOERS}" >&2
  exit 1
fi

install -o root -g root -m 440 "${TMP_SUDOERS}" "${SUDOERS_FILE}"
echo "==> Installed sudoers rules: ${SUDOERS_FILE}"
sed 's/^/       /' "${TMP_SUDOERS}"

# ---------------------------------------------------------------------------
# 6. Verification
# ---------------------------------------------------------------------------
echo
echo "==> Deployment complete. Verify with:"
for name in "${ZERO_ARG_COMMANDS[@]}"; do
  echo "     sudo -u jenkins sudo ${INSTALL_DIR}/${name}              # should run normally"
  echo "     sudo -u jenkins sudo ${INSTALL_DIR}/${name} anything      # must be REJECTED"
done
echo
echo "==> Reminder: if the secrets file already existed and still has"
echo "    REPLACE_ME placeholders, edit it now:"
echo "     ${EDITOR:-vi} ${SECRETS_FILE}"
