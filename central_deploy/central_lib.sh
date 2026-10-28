# shellcheck shell=bash
# Shared by setup_central.sh and deploy_central_jenkins.sh. Sourced only;
# callers set REPO_ROOT and source deploy_verify.sh first.

# A disaster-recovery script can't assume the target machine has anything
# beyond a base OS — install whatever's missing rather than failing.
# Supported: dnf (CentOS Stream / RHEL / Rocky / Fedora) and apt (Ubuntu
# 22.04). The Ansible role handles the same two.
install_prereqs() {
    local pm
    if command -v dnf >/dev/null 2>&1; then
        pm=dnf
    elif command -v apt-get >/dev/null 2>&1; then
        pm=apt
    else
        echo "✗ Unsupported OS: needs dnf (CentOS/RHEL/Fedora) or apt (Ubuntu)" >&2
        exit 1
    fi

    # Command -> package; only the YAML module's package name differs.
    declare -A pkg_for_cmd=( [ansible-playbook]=ansible [python3]=python3 [curl]=curl [git]=git [openssl]=openssl )
    local missing_pkgs=()
    local cmd
    for cmd in ansible-playbook python3 curl git openssl; do
        command -v "$cmd" >/dev/null 2>&1 || missing_pkgs+=("${pkg_for_cmd[$cmd]}")
    done
    # deploy_verify.sh parses the config with python3's yaml module.
    if ! python3 -c 'import yaml' >/dev/null 2>&1; then
        if [[ "$pm" == dnf ]]; then missing_pkgs+=(python3-pyyaml); else missing_pkgs+=(python3-yaml); fi
    fi

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        echo "→ Installing missing prerequisites: ${missing_pkgs[*]}..."
        if [[ "$pm" == dnf ]]; then
            # ansible isn't in CentOS Stream's base/AppStream repos — needs
            # EPEL first. Not needed on Fedora, already in its base repos.
            if [[ "${missing_pkgs[*]}" =~ (^|[[:space:]])ansible($|[[:space:]]) ]] \
                && [[ "$(. /etc/os-release && echo "$ID")" != "fedora" ]] \
                && ! dnf list installed epel-release >/dev/null 2>&1; then
                echo "→ Installing EPEL (required for the ansible package)..."
                dnf install -y epel-release
            fi
            dnf install -y "${missing_pkgs[@]}"
        else
            DEBIAN_FRONTEND=noninteractive apt-get update -q
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing_pkgs[@]}"
        fi
    fi

    # The distro `ansible` packages bundle community.general (the role's
    # alternatives module); a bare ansible-core install doesn't. Catch that
    # here with a fix, not mid-playbook.
    if ! ansible-doc -t module community.general.alternatives >/dev/null 2>&1; then
        echo "✗ Ansible collection community.general is missing (ansible-core alone doesn't ship it)." >&2
        echo "  Install it: ansible-galaxy collection install community.general" >&2
        exit 1
    fi
}

# The GerritHub project each job is triggered by (its main repo) — the
# first project-level `pattern: '<owner>/<repo>'` in jobs/<name>/Jenkinsfile
# (file-path patterns carry a `*`, so never match) — one per line, each
# once. Jobs with no Gerrit trigger (periodic-tasks) have none;
# jenkins-dr-test is CI's own test job, not a real one.
job_main_repos() {
    local repo_root="$1" jenkinsfile
    for jenkinsfile in "${repo_root}"/jobs/*/Jenkinsfile; do
        [[ "$(basename "$(dirname "$jenkinsfile")")" == jenkins-dr-test ]] && continue
        grep -oE "^ +pattern: '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+'" "$jenkinsfile" \
            | head -1 | sed -E "s/^ +pattern: '(.*)'$/\1/"
    done | sort -u
}

detect_public_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$ip" ]]; then
        echo "✗ Could not auto-detect this machine's IP" >&2
        exit 1
    fi
    echo "$ip"
}

# Splits jenkins_url (already validated by load_central_account) — or, when
# blank, https://<auto-detected IP> — into the parts nginx and Jenkins need.
# Sets JENKINS_EXT_URL (no trailing /), JENKINS_SCHEME, JENKINS_HOST,
# JENKINS_LISTEN_PORT (nginx's; 443/80 unless the URL names one) and
# JENKINS_PREFIX ("" or e.g. "/jenkins").
resolve_jenkins_url() {
    if [[ -n "$CENTRAL_JENKINS_URL" ]]; then
        JENKINS_EXT_URL="$CENTRAL_JENKINS_URL"
        echo "→ Using configured jenkins_url: ${JENKINS_EXT_URL}"
    else
        JENKINS_EXT_URL="https://$(detect_public_ip)"
        echo "→ Auto-detected URL: ${JENKINS_EXT_URL} (set jenkins_url in gerrit_central.yml to override)"
    fi
    [[ "$JENKINS_EXT_URL" =~ ^(https?)://([^/:]+)(:([0-9]+))?(/.*)?$ ]] \
        || { echo "✗ Can't parse jenkins_url ${JENKINS_EXT_URL}" >&2; exit 1; }
    JENKINS_SCHEME="${BASH_REMATCH[1]}"
    JENKINS_HOST="${BASH_REMATCH[2]}"
    JENKINS_LISTEN_PORT="${BASH_REMATCH[4]}"
    JENKINS_PREFIX="${BASH_REMATCH[5]}"
    if [[ -z "$JENKINS_LISTEN_PORT" ]]; then
        if [[ "$JENKINS_SCHEME" == https ]]; then JENKINS_LISTEN_PORT=443; else JENKINS_LISTEN_PORT=80; fi
    fi

    # Jenkins' own localhost port: the config's jenkins_internal_port, else the
    # role default. Can't be the port nginx listens on.
    JENKINS_INTERNAL_PORT="${CENTRAL_JENKINS_INTERNAL_PORT:-$(python3 -c "import yaml; print(yaml.safe_load(open('${REPO_ROOT}/central_deploy/roles/jenkins/defaults/main.yml'))['jenkins_internal_port'])")}"
    if [[ "$JENKINS_INTERNAL_PORT" == "$JENKINS_LISTEN_PORT" ]]; then
        echo "✗ jenkins_internal_port ${JENKINS_INTERNAL_PORT} is also the port in jenkins_url — nginx and Jenkins can't share it" >&2
        exit 1
    fi
}

# Markers for what this repo's install owns — setup_central.sh's
# --replace-old-jenkins never touches anything carrying them.
MANAGED_UNIT_MARKER="# Managed by central_deploy (roles/jenkins)"
MANAGED_HOME_MARKER_FILE=".central_deploy_managed"

# PIDs listening on Jenkins' internal port that are NOT the jenkins
# systemd service's main process — i.e. something left over (an old
# Jenkins started by hand, or another service). Empty when the port is
# free or only ours holds it. Needs JENKINS_INTERNAL_PORT.
foreign_port_holders() {
    local own_pid pid
    own_pid=$(systemctl show -p MainPID --value jenkins 2>/dev/null || true)
    for pid in $(ss -ltnpH "sport = :${JENKINS_INTERNAL_PORT}" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
        [[ "$pid" == "$own_pid" ]] || echo "$pid"
    done
}
