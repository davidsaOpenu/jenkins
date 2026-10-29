# Shared by setup_students.sh and reset_students.sh. Sourced only — how
# both log in to the central Jenkins as admin.

err() { echo -e "\033[1;33mERROR: $*\033[0m" >&2; }

# Sets JENKINS_URL / JENKINS_USER / JENKINS_PASS. Each comes from the
# environment (JENKINS_URL, JENKINS_ADMIN_USER, JENKINS_ADMIN_PASSWORD —
# how CI passes them), otherwise it is asked for on the terminal.
load_jenkins_connection() {
    JENKINS_URL="${JENKINS_URL:-}"
    JENKINS_USER="${JENKINS_ADMIN_USER:-}"
    JENKINS_PASS="${JENKINS_ADMIN_PASSWORD:-}"
    [[ -n "$JENKINS_URL" ]]  || read -rp "Jenkins URL (gerrit_central.yml's jenkins_url, e.g. https://<host>:<port>/jenkins): " JENKINS_URL || true
    [[ -n "$JENKINS_USER" ]] || read -rp "Admin user: " JENKINS_USER || true
    if [[ -z "$JENKINS_PASS" ]]; then
        read -rsp "Admin password: " JENKINS_PASS || true
        echo "" >&2
    fi
    JENKINS_URL="${JENKINS_URL%/}"
    [[ -n "$JENKINS_URL" && -n "$JENKINS_USER" && -n "$JENKINS_PASS" ]] \
        || { err "Jenkins URL, admin user and admin password are all required — type them when asked, or set JENKINS_URL, JENKINS_ADMIN_USER, JENKINS_ADMIN_PASSWORD"; exit 1; }
    check_jenkins_connection
}

# Central's self-signed certificate, where deploy_central_jenkins.sh makes it.
CENTRAL_SELF_SIGNED_CERT="/etc/jenkins-dr/tls/jenkins-dr.crt"

# Fails early with the actual cause. The real calls use curl -sf, which
# reduces an untrusted certificate, a wrong address and a wrong password
# all to the same failure — this tells them apart: /login first (public:
# certificate, address, path), then the login, then admin rights.
check_jenkins_connection() {
    local errfile rc out code redirect msg
    errfile=$(mktemp)
    out=$(curl -sS -o /dev/null --max-time 20 -w '%{http_code} %{redirect_url}' "${JENKINS_URL}/login" 2>"$errfile") && rc=0 || rc=$?
    # On the central machine, untrusted by default: try its own self-signed
    # certificate, and keep it for every curl after. Only as a fallback — the
    # file stays behind after switching to a real certificate.
    if [[ ( "$rc" == 51 || "$rc" == 60 ) && -z "${CURL_CA_BUNDLE:-}" && -r "$CENTRAL_SELF_SIGNED_CERT" ]] \
        && out=$(CURL_CA_BUNDLE="$CENTRAL_SELF_SIGNED_CERT" curl -sS -o /dev/null --max-time 20 -w '%{http_code} %{redirect_url}' "${JENKINS_URL}/login" 2>"$errfile"); then
        rc=0
        export CURL_CA_BUNDLE="$CENTRAL_SELF_SIGNED_CERT"
    fi
    code="${out%% *}"
    redirect="${out#* }"
    # "curl: (28) Connection timed out…" → "Connection timed out…"
    msg=$(cat "$errfile"); rm -f "$errfile"
    msg="${msg#curl: (*) }"
    case "$rc" in
        0) ;;
        51|60)
            if [[ -n "${CURL_CA_BUNDLE:-}" ]]; then
                err "${JENKINS_URL} presents a certificate that CURL_CA_BUNDLE (${CURL_CA_BUNDLE}) doesn't vouch for — point it at central's own ${CENTRAL_SELF_SIGNED_CERT} (a copy of it, if not on the central machine)"
            elif [[ -r "$CENTRAL_SELF_SIGNED_CERT" ]]; then
                err "${JENKINS_URL}'s certificate isn't trusted, by the system or by ${CENTRAL_SELF_SIGNED_CERT} — check jenkins_url names this machine, and that a real certificate's intermediates are in tls_cert_file"
            else
                err "${JENKINS_URL}'s certificate isn't trusted (self-signed?) — copy ${CENTRAL_SELF_SIGNED_CERT} from the central machine, then run first:\n  export CURL_CA_BUNDLE=<path to that copy>"
            fi
            exit 1 ;;
        77)
            err "can't read CURL_CA_BUNDLE (${CURL_CA_BUNDLE:-}) — check the path"; exit 1 ;;
        6|7|28)
            err "can't reach ${JENKINS_URL} (${msg}) — check the host and port (gerrit_central.yml's jenkins_url), and that the port is open from this machine"; exit 1 ;;
        *)
            err "can't connect to ${JENKINS_URL} (${msg}) — check the URL: jenkins_url exactly, https/http, port and path included"; exit 1 ;;
    esac
    case "$code" in
        200) ;;
        301|302|307|308)
            err "${JENKINS_URL}/login redirects to ${redirect} — use jenkins_url exactly (https rather than http?)"; exit 1 ;;
        *)
            err "no Jenkins login page at ${JENKINS_URL}/login (HTTP ${code}) — wrong path? Use jenkins_url exactly, path included (e.g. https://<host>:<port>/jenkins)"; exit 1 ;;
    esac

    code=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' -u "${JENKINS_USER}:${JENKINS_PASS}" "${JENKINS_URL}/api/json")
    case "$code" in
        200) ;;
        401) err "Jenkins rejected user '${JENKINS_USER}' or its password (HTTP 401)"; exit 1 ;;
        *)   err "logging in as '${JENKINS_USER}' got HTTP ${code} from ${JENKINS_URL}/api/json"; exit 1 ;;
    esac
    code=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' -u "${JENKINS_USER}:${JENKINS_PASS}" "${JENKINS_URL}/manage/")
    [[ "$code" == "200" ]] \
        || { err "'${JENKINS_USER}' can log in but isn't a Jenkins admin (HTTP ${code} from /manage/) — use central's admin account (gerrit_username)"; exit 1; }
}

get_crumb() {
    curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        "${JENKINS_URL}/crumbIssuer/api/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])"
}
