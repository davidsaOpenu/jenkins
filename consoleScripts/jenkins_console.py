#!/usr/bin/env python3
"""Run consoleScripts/*.groovy on Jenkins from the command line.

The same file you would paste into Manage Jenkins -> Script Console, sent to
the same engine (/scriptText), with the same output. The files themselves
are never changed, so pasting them in the console keeps working.

  jenkins_console.py list
  jenkins_console.py run <script> [name=value ...] [--dry-run]

<script> is a script in consoleScripts/ (".groovy" optional) or a path.
name=value overrides the script's top-level `def name = <literal>` line (its
CONFIGURATION), e.g. targetJobName=swiftacular: a string setting takes the
value as text, a true/false or number setting a value of that kind. Code
lines (`def x = Jenkins.instance`) are not settings.

Connection (option, or environment variable):
  --url     JENKINS_URL     Jenkins' URL, e.g. https://jenkins.example
  --user    JENKINS_USER    a Jenkins admin (the script console is admin-only)
  --cacert  JENKINS_CACERT  CA certificate for a self-signed Jenkins, e.g.
                            the deploy's /etc/jenkins-dr/tls/jenkins-dr.crt
The user's API token (or password) comes from JENKINS_TOKEN, else it is
asked for without echo — never from the command line, where every local
user could read it (ps).

Exit status of `run`: 0 if the script ran to its end, 1 if it threw or
stopped early (Jenkins answers 200 either way; a marker line appended to the
script tells the two apart), 2 on a usage or connection error.

Standard library only: runs wherever python3 does, nothing to install.
"""

import argparse
import base64
import getpass
import http.cookiejar
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DONE_MARKER = "__jenkins_console_script_done__"
# A top-level `def name = <literal>`: a string, true/false or an integer.
SETTING_RE = re.compile(r'^def (\w+) = ("(?:[^"\\]|\\.)*"|true|false|-?\d+)(?=\s|$)')


class UsageError(Exception):
    """Bad arguments or an unusable script: exit 2 with the message."""


# --- Scripts and their settings ----------------------------------------------

def resolve_script(name):
    for candidate in (Path(name), SCRIPT_DIR / name, SCRIPT_DIR / f"{name}.groovy"):
        if candidate.is_file():
            return candidate
    raise UsageError(f"no such script: {name} (see `list`)")


def settings(lines):
    """{name: (line index, regex match)} for each setting, in file order."""
    found = {}
    for i, line in enumerate(lines):
        m = SETTING_RE.match(line)
        if m:
            found[m.group(1)] = (i, m)
    return found


def groovy_literal(name, old, value):
    """value as a literal of the same kind as the setting's default, old."""
    if old.startswith('"'):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")
        return f'"{escaped}"'
    if old in ("true", "false"):
        if value not in ("true", "false"):
            raise UsageError(f"{name} is true/false, not {value!r}")
        return value
    if not re.fullmatch(r"-?\d+", value):
        raise UsageError(f"{name} is a number, not {value!r}")
    return value


def render(path, overrides):
    """The script as it will run: settings overridden, done marker appended."""
    lines = path.read_text().split("\n")
    known = settings(lines)
    for override in overrides:
        name, sep, value = override.partition("=")
        if not sep or name not in known:
            raise UsageError(f"{override!r}: not a setting of {path.name}"
                             f" — it has: {', '.join(known) or 'none'}")
        i, m = known[name]
        new = groovy_literal(name, m.group(2), value)
        lines[i] = lines[i][:m.start(2)] + new + lines[i][m.end(2):]
    return "\n".join(lines).rstrip("\n") + f'\nprintln "{DONE_MARKER}"\n'


# --- Jenkins -------------------------------------------------------------------

class Jenkins:
    """An authenticated session with one Jenkins: cookies kept, so the crumb
    (CSRF token) stays valid for the requests that follow it."""

    def __init__(self, url, user, token, cacert=None):
        self.url = url.rstrip("/")
        context = ssl.create_default_context(cafile=cacert) if cacert else None
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            # Production exports a broken proxy (see run_common.sh); Jenkins
            # is reached directly.
            urllib.request.ProxyHandler({}),
        )
        auth = base64.b64encode(f"{user}:{token}".encode()).decode()
        self.headers = {"Authorization": f"Basic {auth}"}
        self._crumb = None

    def request(self, path, data=None, headers=None):
        req = urllib.request.Request(f"{self.url}{path}", data=data,
                                     headers={**self.headers, **(headers or {})})
        try:
            with self.opener.open(req, timeout=600) as resp:
                return resp.read().decode()
        except urllib.error.HTTPError as e:
            hint = " (wrong user or token, or not an admin)" if e.code in (401, 403) else ""
            raise UsageError(f"{self.url}{path} answered HTTP {e.code}{hint}") from e
        except urllib.error.URLError as e:
            raise UsageError(f"can't reach {self.url}: {e.reason}") from e

    def crumb(self):
        """Only needed with a password (an API token is exempt), but asking
        costs nothing and works with both; none if CSRF protection is off."""
        if self._crumb is None:
            try:
                d = json.loads(self.request("/crumbIssuer/api/json"))
                self._crumb = {d["crumbRequestField"]: d["crumb"]}
            except UsageError:
                self._crumb = {}
        return self._crumb

    def script_text(self, script):
        """Runs a Groovy script as the script console does; its output."""
        data = urllib.parse.urlencode({"script": script}).encode()
        return self.request("/scriptText", data=data, headers=self.crumb())


def connect(args):
    url = args.url or os.environ.get("JENKINS_URL")
    user = args.user or os.environ.get("JENKINS_USER")
    if not url or not user:
        raise UsageError("--url/JENKINS_URL and --user/JENKINS_USER are required")
    token = os.environ.get("JENKINS_TOKEN") or getpass.getpass(f"API token (or password) for {user}: ")
    return Jenkins(url, user, token, args.cacert or os.environ.get("JENKINS_CACERT"))


# --- Commands ------------------------------------------------------------------

def cmd_list(args):
    for path in sorted(SCRIPT_DIR.glob("*.groovy")):
        print(path.stem)
        for name, (_, m) in settings(path.read_text().split("\n")).items():
            print(f"    {name} = {m.group(2)}")
    return 0


def cmd_run(args):
    path = resolve_script(args.script)
    script = render(path, args.settings)
    if args.dry_run:
        print(script.replace(f'println "{DONE_MARKER}"\n', ""), end="")
        return 0
    out = connect(args).script_text(script)
    lines = out.splitlines()
    if DONE_MARKER in lines:
        print("\n".join(l for l in lines if l != DONE_MARKER))
        return 0
    print(out, end="" if out.endswith("\n") else "\n")
    print(f"✗ {path.name} did not run to its end (an exception above, or it stopped early)",
          file=sys.stderr)
    return 1


def parser():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                epilog=__doc__.split("\n\n", 1)[1],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="list the scripts and their settings").set_defaults(func=cmd_list)

    run = sub.add_parser("run", help="run a script on Jenkins")
    run.add_argument("script", help="a script in consoleScripts/ (.groovy optional), or a path")
    run.add_argument("settings", nargs="*", metavar="name=value",
                     help="override one of the script's settings")
    run.add_argument("--dry-run", action="store_true", help="print the script that would run")
    run.add_argument("--url", help="Jenkins' URL (JENKINS_URL)")
    run.add_argument("--user", help="a Jenkins admin (JENKINS_USER)")
    run.add_argument("--cacert", help="CA certificate for a self-signed Jenkins (JENKINS_CACERT)")
    run.set_defaults(func=cmd_run)
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        return args.func(args)
    except UsageError as e:
        print(f"✗ {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
