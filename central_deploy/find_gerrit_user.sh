#!/usr/bin/env bash
# Finds students' GerritHub usernames from their email addresses — the
# username, not the email, is what goes in students.yaml as `name`.
#
# Usage: ./find_gerrit_user.sh [-f <emails.txt>] [--update <students.yaml>]
#                              [--project <label>] [<email>...]
#   <email>...         emails on the command line, and/or
#   -f <emails.txt>    a file of them — anything with an address in it per
#                      line ("Jane Doe <jane@x.org>", CSV rows, ...); lines
#                      starting with # are skipped
#   --update <file>    also append each found student missing from that
#                      students.yaml (created if missing), with a random
#                      password (never printed)
#   --project <label>  project label for appended students (default: all)
#
# No login needed. Exits 1 if any email has no usable GerritHub account
# (the others are still printed / added).
set -euo pipefail

GERRIT_URL="${GERRIT_URL:-https://review.gerrithub.io}"

# Broken proxy env — see run_common.sh for why. Strip it.
unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY

usage() { sed -n '5,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

files=() emails=() update="" project="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)        [[ $# -ge 2 ]] || usage; files+=("$2"); shift 2 ;;
        --update)  [[ $# -ge 2 ]] || usage; update="$2"; shift 2 ;;
        --project) [[ $# -ge 2 ]] || usage; project="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*)        echo "Unknown option: $1" >&2; usage ;;
        *)         emails+=("$1"); shift ;;
    esac
done
[[ ${#emails[@]} -gt 0 || ${#files[@]} -gt 0 ]] || usage
for f in ${files[@]+"${files[@]}"}; do
    [[ -r "$f" ]] || { echo "ERROR: cannot read $f" >&2; exit 1; }
done
if [[ -n "$update" ]] && ! { [[ -w "$update" ]] ||
        { [[ ! -e "$update" ]] && [[ -w "$(dirname "$update")" ]]; }; }; then
    echo "ERROR: cannot write $update" >&2
    exit 1
fi

# Argv after '-' reaches python as sys.argv[1:]: files, then emails, split
# by a '--' marker.
GERRIT_URL="$GERRIT_URL" UPDATE="$update" PROJECT="$project" \
    python3 -u - ${files[@]+"${files[@]}"} -- ${emails[@]+"${emails[@]}"} <<'PY'
import json, os, re, secrets, string, sys, tempfile, urllib.parse, urllib.request
import yaml

args = sys.argv[1:]
sep = args.index("--")
files, raw = args[:sep], args[sep + 1:]
for path in files:
    with open(path) as f:
        raw += [l for l in f if not l.lstrip().startswith("#")]

EMAIL = re.compile(r"[\w.+'-]+@[\w-]+(?:\.[\w-]+)+")
emails, seen = [], set()
for chunk in raw:
    found = EMAIL.findall(chunk)
    if not found and chunk.strip():
        print(f"SKIPPED: no email address in {chunk.strip()!r}", file=sys.stderr)
    for e in found:
        if e.lower() not in seen:
            seen.add(e.lower())
            emails.append(e)

def lookup(email):
    # The account suggest search matches on email (and name), anonymously.
    # Only an exact (case-insensitive) email match counts.
    q = urllib.parse.urlencode({"suggest": "", "q": email, "n": 10})
    url = f"{os.environ['GERRIT_URL']}/accounts/?{q}"
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            text = r.read().decode()
    except OSError as e:
        sys.exit(f"ERROR: cannot reach {os.environ['GERRIT_URL']} ({e})")
    if text.startswith(")]}"):   # Gerrit's anti-XSSI prefix line
        text = text[text.index("\n") + 1:]
    return [a for a in json.loads(text) if a.get("email", "").lower() == email.lower()]

found, failed = [], False
for email in emails:
    hits = lookup(email)
    if not hits:
        print(f"NOT FOUND: {email} - no GerritHub account with that email. Ask "
              "the student to sign in to GerritHub once, or for their username.",
              file=sys.stderr)
        failed = True
        continue
    if len(hits) > 1:
        ids = ", ".join(str(a["_account_id"]) for a in hits)
        print(f"AMBIGUOUS: {email} - several accounts ({ids}); ask the student "
              "which username is theirs.", file=sys.stderr)
        failed = True
        continue
    a = hits[0]
    if not a.get("username"):
        print(f"NO USERNAME: {email} - account {a['_account_id']} has none yet; "
              "the student must set one in GerritHub settings.", file=sys.stderr)
        failed = True
        continue
    name = a.get("name", "-")
    print(f"{email}: username {a['username']!r}  (name: {name}, account {a['_account_id']})")
    found.append((a["username"], name, email))

update = os.environ["UPDATE"]
if not update:
    if found:
        print("\nstudents.yaml entries (fill in project and password):")
        for user, name, email in found:
            print(f"  - name: {json.dumps(user)}          # {name} <{email}>")
            print('    project: ""')
            print('    password: ""')
    sys.exit(1 if failed else 0)

if os.path.exists(update):
    with open(update) as f:
        text = f.read()
else:
    text = ("# Instructor setup file - see SETUP_STUDENTS.md. Keep it private:\n"
            "# it holds passwords (gitignored). Then run ./setup_students.sh\n\n"
            "students: []\n")
data = yaml.safe_load(text) or {}
students = data.get("students") or []
# The students list must be the file's last key: entries are appended as
# text, so its comments and layout stay as they are.
if list(data)[-1:] != ["students"]:
    sys.exit(f"ERROR: {update}: 'students:' must be the last section to append to")
if any(not str(s.get("name") or "").strip() for s in students):
    print(f"WARNING: {update} has entries with an empty name (left over from "
          "students.yaml.example?) - delete them before ./setup_students.sh",
          file=sys.stderr)
# Jenkins ids are case-insensitive, so are duplicates.
have = {str(s.get("name", "")).lower() for s in students}
alphabet = string.ascii_letters + string.digits
added = []
for user, name, email in found:
    if user.lower() in have:
        print(f"already in {update}: {user}")
        continue
    have.add(user.lower())
    password = "".join(secrets.choice(alphabet) for _ in range(16))
    added.append(f'  - name: {json.dumps(user)}          # {name} <{email}>\n'
                 f'    project: {json.dumps(os.environ["PROJECT"])}\n'
                 f'    password: {json.dumps(password)}\n')
if added:
    if not students and re.search(r"^students:\s*(\[\]\s*)?$", text, re.M) is None:
        sys.exit(f"ERROR: {update}: no 'students:' list found")
    text = text.rstrip("\n") + "\n" + "".join("\n" + e for e in added)
    text = re.sub(r"^students:\s*\[\]\s*$", "students:", text, flags=re.M)
    check = yaml.safe_load(text)["students"]
    assert len(check) == len(students) + len(added), "append went wrong"
    # Owner-only, replaced atomically: the file holds passwords.
    d = os.path.dirname(os.path.abspath(update))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".students.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, update)
    print(f"added {len(added)} student(s) to {update} - passwords generated; "
          "now run ./setup_students.sh")
else:
    print(f"nothing to add to {update}")
sys.exit(1 if failed else 0)
PY
