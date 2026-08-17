#!/usr/bin/env bash
#
# gerrit_multi_user_push.sh
#
# DEPLOYMENT (do this once, as root, outside any repo):
#
#   Run the companion deploy script from the SAME DIRECTORY as this
#   file — it installs this script, creates the secrets file/dir, and
#   configures the sudoers rule below, all in one idempotent step:
#
#     cd /path/to/dir/containing/this/file
#     sudo ./deploy_gerrit_multi_user_push.sh
#
#   See deploy_gerrit_multi_user_push.sh for exactly what it does; the
#   manual equivalent (for reference, or if you'd rather do it by hand)
#   is documented in that script's own header comment.
#
# SUDOERS (locked to zero arguments — see note below):
#
#   The deploy script installs this automatically as
#   /etc/sudoers.d/gerrit-push:
#
#   jenkins ALL=(root) NOPASSWD: /opt/ci/gerrit_multi_user_push.sh ""
#
#   The trailing "" is not decorative — sudoers only restricts arguments
#   if an argument spec is present. A bare path with no argument list
#   permits ANY arguments to be appended by the caller. The empty string
#   is sudoers' explicit syntax for "this command may only be run with
#   no arguments at all." Verify with:
#     sudo /opt/ci/gerrit_multi_user_push.sh            # allowed
#     sudo /opt/ci/gerrit_multi_user_push.sh anything    # must be rejected
#
# JENKINSFILE CALL:
#
#   stage('Push test changes') {
#       steps {
#           sh 'sudo /opt/ci/gerrit_multi_user_push.sh'
#       }
#   }
#
# ---------------------------------------------------------------------------
# This script must live outside any repository a Gerrit patch author can
# modify (i.e. NOT inside davidsaOpenu/jenkins), and must run entirely as
# root. Every step that touches key material — generation, registration,
# use for git operations, deregistration, deletion — happens inside this
# single root process. Private key material is NEVER written to a path
# readable by the `jenkins` user, and is never handed off to any other
# script (which could otherwise be swapped out or read by code checked
# out from the patch under test). The sudoers rule accepts zero arguments,
# so an attacker-controlled Jenkinsfile has no parameter surface to abuse.
#
# WHAT IT DOES, per GerritHub user in USERS:
#   1. Generates a fresh, single-use ed25519 SSH keypair
#   2. Registers the public key on that user's GerritHub account via the
#      REST API, using that user's own HTTP token (never a shared admin
#      credential — a compromised token only ever affects one account)
#   3. Clones the target repo using the ephemeral private key
#   4. Installs the commit-msg hook (via SSH/scp)
#   5. Sets local git identity (user.name / user.email)
#   6. Adds a test file
#   7. Commits locally with a fixed Change-Id (so repeat runs create a new
#      patch set on the SAME change, not a new change each time)
#   8. Pushes for review: `git push origin HEAD:refs/for/<branch>`
#   9. Deletes the local clone
#  10. Deregisters the public key from GerritHub and shreds both key files
#
# Steps 9-10 run via a guaranteed RETURN trap, so cleanup happens even if
# an earlier step for that user fails.
#
# Requires: git, curl, ssh-keygen, scp, shred
#
set -uo pipefail
# Deliberately not `set -e` at top level — see process_user() below for why.

# ---------------------------------------------------------------------------
# ROOT-ONLY GUARD — refuse to run unless actually root. This script is
# meaningless (and would silently fail on key ops) run as anything else,
# and this catches misconfiguration early with a clear message.
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: this script must be run as root (via sudo), not as $(id -un)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# BYPASS PROXIES
# ---------------------------------------------------------------------------
unset http_proxy https_proxy ftp_proxy all_proxy no_proxy
unset HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY
git config --global --unset http.proxy 2>/dev/null || true
git config --global --unset https.proxy 2>/dev/null || true

# ---------------------------------------------------------------------------
# SECRETS — loaded from a root-only file, independent of any environment
# variable that could be set/overridden by the calling (jenkins) process.
# sudo's default env_reset means jenkins-set env vars would not reach
# here anyway, but loading tokens from a root-owned file makes that
# explicit and removes any dependency on sudoers env_keep settings.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
GERRIT_HOST="review.gerrithub.io"
GERRIT_PORT="29418"
GERRIT_API_BASE="https://${GERRIT_HOST}/a"
REPO_PATH="davidsaOpenu/swiftacular"     # <org>/<repo> on GerritHub
REPO_NAME="swiftacular"
TARGET_BRANCH="master"

# One entry per user: "gerrit_username|email|display_name|token_var|change_id"
#   gerrit_username = account used in the clone URL (ssh://<user>@host)
#   email           = must be a verified email on that GerritHub account
#   token_var       = name of the shell variable (set by SECRETS_FILE)
#                      holding that user's HTTP token
#   change_id       = fixed Gerrit Change-Id so repeated runs update the
#                      SAME change (new patch set) instead of creating a
#                      new change every run
USERS=(
  "jenkins-osw|osw.jenkins@gmail.com|OSW Jenkins|JENKINS_OSW_TOKEN|I7765583f6b6bbe0543e804c749234dcdd95ef140"
  "jenkins-test-userA|jenkins.test.userA@gmail.com|Jenkins UserA|JENKINS_USERA_TOKEN|Ic719111d55d1a0ed4511c70e3d3f6be21e098d25"
  "jenkins-test-userB|jenkins.test.userB@gmail.com|Jenkins UserB|JENKINS_USERB_TOKEN|Ibc68ac9afe6cf0170e32bf3ac192a9854026a529"
)

# mktemp -d creates this as mode 0700, owned by root (the current euid) —
# unreadable by jenkins or anything else, no extra chmod needed.
WORK_ROOT="$(mktemp -d /tmp/gerrit-multi-push.XXXXXX)"
KNOWN_HOSTS_FILE="${WORK_ROOT}/known_hosts"
OVERALL_STATUS=0

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

json_field() {
  local file="$1" field="$2"
  tail -n +2 "${file}" 2>/dev/null | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*[0-9]+" \
    | grep -oE '[0-9]+$' | head -n1
}

register_ssh_key() {
  local gerrit_user="$1" token="$2" pubkey_file="$3"
  local resp_file="${WORK_ROOT}/${gerrit_user}-add-resp.json"
  local http_code
  http_code=$(curl -sS -o "${resp_file}" -w '%{http_code}' \
    -u "${gerrit_user}:${token}" \
    -H "Content-Type: text/plain" \
    --data-binary "@${pubkey_file}" \
    "${GERRIT_API_BASE}/accounts/self/sshkeys")

  if [[ "${http_code}" != "200" && "${http_code}" != "201" ]]; then
    echo "ERROR: failed to register SSH key for ${gerrit_user} (HTTP ${http_code})" >&2
    return 1
  fi
  json_field "${resp_file}" "seq"
}

deregister_ssh_key() {
  local gerrit_user="$1" token="$2" seq="$3"
  [[ -z "${seq}" ]] && return 0
  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    -u "${gerrit_user}:${token}" \
    "${GERRIT_API_BASE}/accounts/self/sshkeys/${seq}")
  if [[ "${http_code}" != "204" && "${http_code}" != "200" ]]; then
    echo "WARNING: failed to deregister SSH key seq=${seq} for ${gerrit_user} (HTTP ${http_code})" >&2
  else
    echo "Deregistered SSH key seq=${seq} for ${gerrit_user}."
  fi
}

# ---------------------------------------------------------------------------
# PER-USER WORKFLOW
# ---------------------------------------------------------------------------
process_user() {
  local GERRIT_USER="$1" EMAIL="$2" DISPLAY_NAME="$3" TOKEN="$4" CHANGE_ID="$5"
  local USERNAME_PART="${EMAIL%%@*}"
  local KEY_PATH="${WORK_ROOT}/${GERRIT_USER}_ed25519"
  local CLONE_DIR="${WORK_ROOT}/${REPO_NAME}-${GERRIT_USER}"
  local SEQ=""

  trap '
    deregister_ssh_key "${GERRIT_USER}" "${TOKEN}" "${SEQ}"
    shred -u "${KEY_PATH}" "${KEY_PATH}.pub" 2>/dev/null || true
    rm -rf "${CLONE_DIR}"
  ' RETURN

  if ! ssh-keygen -t ed25519 -f "${KEY_PATH}" -N "" -C "ci-${GERRIT_USER}-$(date +%s)" -q; then
    echo "ERROR: keygen failed for ${GERRIT_USER}" >&2
    return 1
  fi
  chmod 600 "${KEY_PATH}"

  SEQ="$(register_ssh_key "${GERRIT_USER}" "${TOKEN}" "${KEY_PATH}.pub")"
  if [[ -z "${SEQ}" ]]; then
    echo "ERROR: could not obtain key seq id for ${GERRIT_USER}" >&2
    return 1
  fi
  echo "Registered SSH key seq=${SEQ} for ${GERRIT_USER}."

  local SSH_OPTS=(-i "${KEY_PATH}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}")

  local i ok=0
  for i in 1 2 3 4 5; do
    if ssh "${SSH_OPTS[@]}" -p "${GERRIT_PORT}" "${GERRIT_USER}@${GERRIT_HOST}" gerrit version >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 2
  done
  if [[ "${ok}" -ne 1 ]]; then
    echo "ERROR: SSH key for ${GERRIT_USER} never became active" >&2
    return 1
  fi

  if ! GIT_SSH_COMMAND="ssh ${SSH_OPTS[*]}" git clone \
        "ssh://${GERRIT_USER}@${GERRIT_HOST}:${GERRIT_PORT}/${REPO_PATH}" "${CLONE_DIR}"; then
    echo "ERROR: clone failed for ${GERRIT_USER}" >&2
    return 1
  fi

  (
    cd "${CLONE_DIR}" || exit 1
    export GIT_SSH_COMMAND="ssh ${SSH_OPTS[*]}"

    hook_file="$(git rev-parse --git-dir)/hooks/commit-msg"
    mkdir -p "$(dirname "${hook_file}")"
    scp "${SSH_OPTS[@]}" -P "${GERRIT_PORT}" \
        "${GERRIT_USER}@${GERRIT_HOST}:hooks/commit-msg" "${hook_file}" || exit 1
    chmod +x "${hook_file}"

    git config user.email "${EMAIL}"
    git config user.name "${DISPLAY_NAME}"

    test_file="test-from-${GERRIT_USER}.txt"
    echo "Test from ${USERNAME_PART} at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${test_file}"
    git add "${test_file}"

    commit_msg="Test from ${USERNAME_PART}

Change-Id: ${CHANGE_ID}"
    git commit -a -m "${commit_msg}" || exit 1

    git push origin "HEAD:refs/for/${TARGET_BRANCH}" || exit 1
  )
  local push_status=$?

  if [[ "${push_status}" -ne 0 ]]; then
    echo "ERROR: clone/commit/push sequence failed for ${GERRIT_USER}" >&2
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------
for entry in "${USERS[@]}"; do
  IFS='|' read -r GERRIT_USER EMAIL DISPLAY_NAME TOKEN_VAR CHANGE_ID <<< "${entry}"

  echo "============================================================"
  echo "User:        ${DISPLAY_NAME} <${EMAIL}>"
  echo "Gerrit user: ${GERRIT_USER}"
  echo "============================================================"

  TOKEN="${!TOKEN_VAR:-}"
  if [[ -z "${TOKEN}" ]]; then
    echo "ERROR: ${TOKEN_VAR} is not set in ${SECRETS_FILE} — skipping ${DISPLAY_NAME}" >&2
    OVERALL_STATUS=1
    echo
    continue
  fi

  if process_user "${GERRIT_USER}" "${EMAIL}" "${DISPLAY_NAME}" "${TOKEN}" "${CHANGE_ID}"; then
    echo "Done with ${DISPLAY_NAME}."
  else
    echo "FAILED: ${DISPLAY_NAME}"
    OVERALL_STATUS=1
  fi
  echo
done

rm -rf "${WORK_ROOT}"
echo "All users processed."
exit "${OVERALL_STATUS}"

