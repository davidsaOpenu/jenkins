# Shared identity source for scripts/gerrit_multi_user_push.sh and the DR
# harness (run.sh). Sourced only. Defines USERS — one entry per identity,
# "gerrit_username|ssh_key_name|email|display_name|change_id" — index 0 is
# always "central", 1/2 are node A/B.

USERS=(
  "jenkins-osw|id_osw_jenkins_dr_ephemeral|osw.jenkins@gmail.com|OSW Jenkins|I7765583f6b6bbe0543e804c749234dcdd95ef140"
  "jenkins-test-userA|id_jenkins_userA|jenkins.test.userA@gmail.com|Jenkins UserA|Ic719111d55d1a0ed4511c70e3d3f6be21e098d25"
  "jenkins-test-userB|id_jenkins_userB|jenkins.test.userB@gmail.com|Jenkins UserB|Ibc68ac9afe6cf0170e32bf3ac192a9854026a529"
)

# Local dev override — only if ~/.gerrit_test_users exists (absent on prod,
# so this is a no-op there). Never sourced/eval'd: each line is validated
# against the exact USERS shape before being accepted, so the file can only
# ever supply data, never executable code.
# Ignored entirely when running as root: the /opt/ci copy runs under sudo,
# and depending on sudo version/Defaults (env_keep += HOME) HOME may still
# be the caller's, letting jenkins pick which account, token, and key name
# the root scripts use.
LOCAL_USERS_FILE="${HOME}/.gerrit_test_users"
if [[ $EUID -ne 0 && -f "$LOCAL_USERS_FILE" ]]; then
  USERS=()
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^[A-Za-z0-9._-]+\|[A-Za-z0-9._-]+\|[^\|[:space:]]+@[^\|[:space:]]+\|[^\|]+\|I[0-9a-f]{40}$ ]] \
      || { echo "✗ Invalid line in ${LOCAL_USERS_FILE}: ${line}" >&2; exit 1; }
    USERS+=("$line")
  done < "$LOCAL_USERS_FILE"
fi
