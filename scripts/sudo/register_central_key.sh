#!/bin/bash
#
# register_central_key.sh
#
# Generates a fresh ed25519 keypair for central Jenkins' Gerrit Trigger
# plugin, registers it on jenkins-osw's GerritHub account, and installs
# the private key where deploy_central_jenkins.sh/load_gerrit_users()
# already expect it: ${HOME}/.ssh/<key_name> for the `jenkins` OS user
# (i.e. /var/lib/jenkins/.ssh/id_osw_jenkins_dr_ephemeral — a name only
# this test uses, so it can never overwrite a real key).
#
# DEPLOYMENT: installed by deploy_gerrit_multi_user_push.sh, alongside
# gerrit_multi_user_push.sh, gerrit_key_lib.sh, and gerrit_users.sh. Runs
# as root via the zero-arg sudoers rule in /etc/sudoers.d/gerrit-push:
#   jenkins ALL=(root) NOPASSWD: /opt/ci/register_central_key.sh ""
#
# CRASH RECOVERY: if a previous run's key was never deregistered (e.g.
# a crashed run before cleanup.sh's deregister_central_key.sh executed),
# best-effort deregister that old seq first, then proceed — self-healing,
# never blocks a new run over stale state.
#
# Requires: ssh-keygen, curl, ssh (connectivity check).
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

# Central is always USERS[0] — same convention gerrit_users.sh's own
# header comment documents ("index 0 is always central").
IFS='|' read -r GERRIT_USER KEY_NAME _EMAIL _DISPLAY_NAME _CHANGE_ID <<< "${USERS[0]}"

KEY_DEST_DIR="/var/lib/jenkins/.ssh"
KEY_DEST="${KEY_DEST_DIR}/${KEY_NAME}"
STATE_DIR="/opt/ci/state"
STATE_FILE="${STATE_DIR}/central_key_seq"

TOKEN_VAR="$(token_var_for "${GERRIT_USER}")"
TOKEN="${!TOKEN_VAR:-}"
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: ${TOKEN_VAR} is not set in ${SECRETS_FILE}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# CRASH RECOVERY — best-effort deregister of a leftover key from a run
# that never reached cleanup.sh. deregister_ssh_key already tolerates a
# missing/expired seq, so this never blocks a fresh registration.
# ---------------------------------------------------------------------------
if [[ -s "${STATE_FILE}" ]]; then
  OLD_SEQ="$(cat "${STATE_FILE}")"
  echo "Found leftover key seq=${OLD_SEQ} from a previous run — deregistering it first."
  deregister_ssh_key "${GERRIT_USER}" "${TOKEN}" "${OLD_SEQ}"
  rm -f "${STATE_FILE}"
fi

mkdir -p "${STATE_DIR}"

# mktemp -d under STATE_DIR keeps the keypair root-only (0700) until it's
# installed to KEY_DEST below.
TMP_DIR="$(mktemp -d "${STATE_DIR}/register_central.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
KEY_PATH="${TMP_DIR}/${KEY_NAME}"

ssh-keygen -t ed25519 -f "${KEY_PATH}" -N "" -C "central-${GERRIT_USER}-$(date +%s)" -q
chmod 600 "${KEY_PATH}"

RESP_FILE="${TMP_DIR}/add-resp.json"
SEQ="$(register_ssh_key "${GERRIT_USER}" "${TOKEN}" "${KEY_PATH}.pub" "${RESP_FILE}")"
if [[ -z "${SEQ}" ]]; then
  echo "ERROR: could not obtain key seq id for ${GERRIT_USER}" >&2
  exit 1
fi
echo "Registered SSH key seq=${SEQ} for ${GERRIT_USER}."

# Recorded right away: if anything below dies, the next run (or
# cleanup.sh) still knows which key to remove from GerritHub.
printf '%s' "${SEQ}" > "${STATE_FILE}"
chmod 600 "${STATE_FILE}"

# Confirm the key is actually live before handing it to Jenkins —
# GerritHub can take a moment to propagate a newly added key.
write_known_hosts "${TMP_DIR}/known_hosts"
SSH_OPTS=(-i "${KEY_PATH}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${TMP_DIR}/known_hosts")
ok=0
for _ in 1 2 3 4 5; do
  if ssh "${SSH_OPTS[@]}" -p "${GERRIT_PORT}" "${GERRIT_USER}@${GERRIT_HOST}" gerrit version >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done
if [[ "${ok}" -ne 1 ]]; then
  deregister_ssh_key "${GERRIT_USER}" "${TOKEN}" "${SEQ}"
  rm -f "${STATE_FILE}"
  echo "ERROR: registered key for ${GERRIT_USER} never became active — deregistered it." >&2
  exit 1
fi

# Every write under /var/lib/jenkins happens AS jenkins, never as root:
# jenkins owns that tree, so it could swap .ssh (or the key path) for a
# symlink to /etc, and a root chown/chmod/install would follow it and hand
# jenkins ownership of the target. Done as jenkins, a symlink only reaches
# what jenkins could already write. Root opens KEY_PATH for the redirect,
# so jenkins never needs read access to STATE_DIR — cat reads that open
# fd as-is. (Not `install /dev/stdin`: it re-opens the path, and for a
# regular file Linux re-checks KEY_PATH's permissions as jenkins → EACCES.)
# chmod after: an existing KEY_DEST keeps its old mode through `>`.
runuser -u jenkins -- mkdir -p -m 700 "${KEY_DEST_DIR}"
runuser -u jenkins -- sh -c 'umask 077 && cat > "$1" && chmod 600 "$1"' sh "${KEY_DEST}" < "${KEY_PATH}"

echo "Central key installed at ${KEY_DEST}, seq=${SEQ} recorded in ${STATE_FILE}."
