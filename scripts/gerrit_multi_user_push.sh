#!/usr/bin/env bash
#
# gerrit_multi_user_submit.sh
#
# For every GerritHub user from USERS:
#   1. Clone the repo using that user's SSH key
#   2. Install the commit-msg hook (via SSH)
#   3. Set local git identity (user.name / user.email)
#   4. Add a test file
#   5. Commit locally
#   6. Submit for review via `git push origin HEAD:refs/for/<branch>`
#   7. Delete the local clone
#
# Requires: git, scp
#
set -euo pipefail

# ---------------------------------------------------------------------------
# BYPASS PROXIES — unset any proxy env vars so git/ssh/scp/curl connect
# directly instead of through a (possibly misconfigured) proxy.
# ---------------------------------------------------------------------------
unset http_proxy https_proxy ftp_proxy all_proxy no_proxy
unset HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY
git config --global --unset http.proxy 2>/dev/null || true
git config --global --unset https.proxy 2>/dev/null || true

# ---------------------------------------------------------------------------
# CONFIG — edit these to match your setup
# ---------------------------------------------------------------------------
GERRIT_HOST="review.gerrithub.io"
GERRIT_PORT="29418"
REPO_PATH="davidsaOpenu/swiftacular"     # <org>/<repo> on GerritHub
REPO_NAME="swiftacular"                  # local dir name after clone
TARGET_BRANCH="master"                   # branch to submit against
# One entry per user: "gerrit_username|ssh_key_name|email|display_name|change_id"
# gerrit_username = the account used in the clone URL (ssh://<user>@host)
# ssh_key_name    = filename under ~/.ssh (private key)
# change_id       = fixed Gerrit Change-Id (Ixxxxxx...) so repeated runs
#                    update the SAME change (new patch set) instead of
#                    creating a new change every time the script runs.
USERS=(
  "jenkins-osw|id_osw_jenkins|osw.jenkins@gmail.com|OSW Jenkins|I7765583f6b6bbe0543e804c749234dcdd95ef140"
  "jenkins-test-userA|id_jenkins_userA|jenkins.test.userA@gmail.com|Jenkins UserA|Ic719111d55d1a0ed4511c70e3d3f6be21e098d25"
  "jenkins-test-userB|id_jenkins_userB|jenkins.test.userB@gmail.com|Jenkins UserB|Ibc68ac9afe6cf0170e32bf3ac192a9854026a529"
)
SSH_DIR="${HOME}/.ssh"
WORK_ROOT="${HOME}/gerrit-multi-submit"  # scratch space, cleaned up per user
# ---------------------------------------------------------------------------
# SCRIPT — shouldn't need to edit below this line
# ---------------------------------------------------------------------------
mkdir -p "${WORK_ROOT}"
for entry in "${USERS[@]}"; do
  IFS='|' read -r GERRIT_USER KEY_NAME EMAIL DISPLAY_NAME CHANGE_ID <<< "${entry}"
  KEY_PATH="${SSH_DIR}/${KEY_NAME}"
  CLONE_DIR="${WORK_ROOT}/${REPO_NAME}-${KEY_NAME}"
  USERNAME_PART="${EMAIL%%@*}"   # local part of the email, e.g. "jenkins.test.userB"
  echo "============================================================"
  echo "User:       ${DISPLAY_NAME} <${EMAIL}>"
  echo "SSH key:    ${KEY_PATH}"
  echo "Gerrit user:${GERRIT_USER}"
  echo "Clone dir:  ${CLONE_DIR}"
  echo "============================================================"
  if [[ ! -f "${KEY_PATH}" ]]; then
    echo "ERROR: SSH key not found at ${KEY_PATH} — skipping ${DISPLAY_NAME}"
    continue
  fi
  # Clean up any stale directory from a previous failed run
  rm -rf "${CLONE_DIR}"
  export GIT_SSH_COMMAND="ssh -i ${KEY_PATH} -o IdentitiesOnly=yes"
  # 1. Clone
  git clone "ssh://${GERRIT_USER}@${GERRIT_HOST}:${GERRIT_PORT}/${REPO_PATH}" "${CLONE_DIR}"
  pushd "${CLONE_DIR}" > /dev/null
  # 2. Install commit-msg hook via SSH (scp) instead of HTTPS (curl)
  #    Avoids TLS/proxy issues on networks that break HTTPS to gerrithub.
  hook_file="$(git rev-parse --git-dir)/hooks/commit-msg"
  mkdir -p "$(dirname "${hook_file}")"
  scp -i "${KEY_PATH}" -o IdentitiesOnly=yes -P "${GERRIT_PORT}" \
      "${GERRIT_USER}@${GERRIT_HOST}:hooks/commit-msg" "${hook_file}"
  chmod +x "${hook_file}"
  # 3. Set local identity for this clone only
  git config user.email "${EMAIL}"
  git config user.name "${DISPLAY_NAME}"
  # 4. Add a test file, under dr_test/ so it only triggers jenkins-dr-test
  mkdir -p dr_test
  test_file="dr_test/test-from-${KEY_NAME}.txt"
  echo "Test from ${USERNAME_PART} at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${test_file}"
  git add "${test_file}"
  # 5. Commit locally
  #    Change-Id is embedded directly in the message so the commit-msg
  #    hook (which only ADDS a Change-Id if one is missing) leaves it
  #    untouched. Reusing the same fixed Change-Id across runs means
  #    each re-run of the script updates the SAME Gerrit change with a
  #    new patch set instead of creating a brand-new change every time.
  commit_msg="Test from ${USERNAME_PART}

Change-Id: ${CHANGE_ID}"
  git commit -a -m "${commit_msg}"
  # 6. Submit for review
  #    Using a plain push to refs/for/<branch> instead of `git review`.
  git push origin "HEAD:refs/for/${TARGET_BRANCH}"
  popd > /dev/null
  # 7. Delete local repository
  rm -rf "${CLONE_DIR}"
  unset GIT_SSH_COMMAND
  echo "Done with ${DISPLAY_NAME}."
  echo
done
# Remove scratch root if empty
rmdir "${WORK_ROOT}" 2>/dev/null || true
echo "All users processed."
