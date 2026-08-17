#!/usr/bin/env bash
#
# gerrit_key_lib.sh
#
# Shared GerritHub SSH-key helpers, sourced by gerrit_multi_user_push.sh,
# register_central_key.sh, and deregister_central_key.sh. Not directly
# executable — defines config + functions (plus the proxy unset below),
# no `set`, so sourcing it never changes the caller's shell options.
#
# Requires: curl (all functions), one HTTP token per call site.

GERRIT_HOST="review.gerrithub.io"
GERRIT_PORT="29418"
GERRIT_API_BASE="https://${GERRIT_HOST}/a"

# BYPASS PROXIES — production exports a broken proxy that curl silently
# honors even for plain HTTPS to GerritHub, causing TLS handshake
# failures ("SSL routines::wrong version number"). Every curl call in
# this lib needs this, so it's unset once here instead of duplicated in
# every script that sources this file.
unset http_proxy https_proxy ftp_proxy all_proxy no_proxy
unset HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY

# Maps a gerrit_username (from gerrit_users.sh, or a ~/.gerrit_test_users
# override) to the secrets-file variable holding its HTTP token.
# Deliberately kept out of gerrit_users.sh: that file is sourced by
# unprivileged (non-root) scripts too, and this mapping must stay inside
# the root-only boundary.
token_var_for() {
  case "$1" in
    # Already-deployed prod names — don't fit the derivation below
    # (drops "TEST_"), kept as explicit exceptions for backward compat
    # with the existing gerrit_tokens.env on production.
    jenkins-test-userA) echo "JENKINS_USERA_TOKEN" ;;
    jenkins-test-userB) echo "JENKINS_USERB_TOKEN" ;;
    *)
      # Derived, not hardcoded — matches the plan's own "name your
      # gerrit_tokens.env var after the account" testing convention.
      # jenkins-osw -> JENKINS_OSW_TOKEN falls out of this too.
      printf '%s_TOKEN\n' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_' | tr -c 'A-Z0-9_' '_')"
      ;;
  esac
}

json_field() {
  local file="$1" field="$2"
  tail -n +2 "${file}" 2>/dev/null | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*[0-9]+" \
    | grep -oE '[0-9]+$' | head -n1
}

register_ssh_key() {
  local gerrit_user="$1" token="$2" pubkey_file="$3" resp_file="$4"
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
