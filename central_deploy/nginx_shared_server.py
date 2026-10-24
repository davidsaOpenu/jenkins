#!/usr/bin/python3
"""Checks for, and attaches Jenkins to, an existing nginx server on
jenkins_url's port.

Normally the jenkins role gives Jenkins its own nginx server. Some machines
only have one usable port — e.g. behind a NAT that forwards just the port an
existing server (shared with other apps) already listens on. There, with
nginx_shared_server: true, Jenkins is attached to that server instead: its
`listen` gets `ssl` (for https) and two includes are added —

    include /etc/nginx/snippets/jenkins-dr-tls.conf;       # https only
    include /etc/nginx/snippets/jenkins-dr-location.conf;

— both written by the role. Nothing else in the file changes. Idempotent.

Usage (as root):
  nginx_shared_server.py check  --port 8080 --mode standalone|shared
  nginx_shared_server.py attach --port 8080 [--tls]

check, standalone: fails if an existing server on the port serves proxied
  apps — a separate Jenkins server there would take their requests.
check, shared: fails unless exactly one existing server listens on it.
attach: backs up the file, edits, runs nginx -t, restores on failure.
Exit codes: 0 ok, 1 error, 3 check failed.
"""
import argparse
import datetime
import os
import shutil
import subprocess
import sys

# Run as root from a user's checkout: don't leave a root-owned __pycache__.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nginx_jenkins_proxies import candidate_files, parse  # noqa: E402

SNIPPET_DIR = "/etc/nginx/snippets"
TLS_SNIPPET = os.path.join(SNIPPET_DIR, "jenkins-dr-tls.conf")
LOCATION_SNIPPET = os.path.join(SNIPPET_DIR, "jenkins-dr-location.conf")


def listen_port(directive):
    """Port of a `listen` directive: "8080", "[::]:8080", "1.2.3.4:8080",
    an address alone (nginx's default, 80); None for unix sockets."""
    addr = directive["args"][0] if directive["args"] else ""
    if not addr or addr.startswith("unix:"):
        return None
    if addr.isdigit():
        return int(addr)
    _, sep, port = addr.rpartition(":")
    if sep and port.isdigit() and not addr.endswith("]"):
        return int(port)
    return 80


def walk(items):
    for item in items:
        yield item
        yield from walk(item.get("children", []))


def servers_on_port(port):
    """[(path, text, server_block, [listen directives on port])] across the
    candidate files (this install's own conf.d/jenkins.conf excluded)."""
    found = []
    for path in candidate_files():
        text = open(path).read()
        for block in walk(parse(text)):
            if block["name"] != "server" or "children" not in block:
                continue
            listens = [c for c in block["children"] if c["name"] == "listen" and listen_port(c) == port]
            if listens:
                found.append((path, text, block, listens))
    return found


def describe(path, text, block):
    line = text.count("\n", 0, block["start"]) + 1
    proxies = sorted({" ".join(c["args"]) for c in walk(block["children"]) if c["name"] == "location"})
    return f"  {path}:{line}: server{' (locations: ' + ', '.join(proxies) + ')' if proxies else ''}"


def serves_proxied_apps(block):
    return any(c["name"] == "proxy_pass" for c in walk(block["children"]))


def check(port, mode):
    found = servers_on_port(port)
    if mode == "standalone":
        busy = [f for f in found if serves_proxied_apps(f[2])]
        if busy:
            print(f"✗ An existing nginx server already serves apps on port {port}:", file=sys.stderr)
            for path, text, block, _ in busy:
                print(describe(path, text, block), file=sys.stderr)
            print(f"  A separate Jenkins server on {port} would take their requests. Either use a\n"
                  f"  free port in jenkins_url, or set nginx_shared_server: true to attach Jenkins\n"
                  f"  to that server instead.", file=sys.stderr)
            return 3
        return 0
    if len(found) != 1:
        print(f"✗ nginx_shared_server: true needs exactly one existing nginx server listening on\n"
              f"  port {port} (jenkins_url's port); found {len(found)}.", file=sys.stderr)
        for path, text, block, _ in found:
            print(describe(path, text, block), file=sys.stderr)
        return 3
    return 0


def attach(port, tls):
    if check(port, "shared") != 0:
        return 1
    path, text, block, listens = servers_on_port(port)[0]
    children = block["children"]
    included = {c["args"][0] for c in children if c["name"] == "include" and c["args"]}
    has_own_cert = any(c["name"] == "ssl_certificate" for c in children)

    edits = []  # (offset, text to insert), applied back to front
    if tls:
        for d in listens:
            if "ssl" not in d["args"]:
                edits.append((d["end"] - 1, " ssl"))  # before the ';'
    wanted = []
    if tls and not has_own_cert and TLS_SNIPPET not in included:
        wanted.append(TLS_SNIPPET)
    if LOCATION_SNIPPET not in included:
        wanted.append(LOCATION_SNIPPET)
    if wanted:
        last = max(listens, key=lambda d: d["end"])
        line_start = text.rfind("\n", 0, last["start"]) + 1
        indent = text[line_start:last["start"]] if text[line_start:last["start"]].strip() == "" else "    "
        edits.append((last["end"], "".join(f"\n{indent}include {w};" for w in wanted)))

    if not edits:
        print(f"→ nginx server in {path} already serves Jenkins on port {port}")
        return 0

    new = text
    for offset, insert in sorted(edits, reverse=True):
        new = new[:offset] + insert + new[offset:]
    backup = f"{path}.bak-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    with open(path, "w") as f:
        f.write(new)
    check_run = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
    if check_run.returncode != 0:
        shutil.copy2(backup, path)
        print(f"✗ nginx -t failed after attaching Jenkins — {path} restored from {backup}:\n"
              + check_run.stderr, file=sys.stderr)
        return 1
    what = (["listen … ssl"] if tls and any(e[1] == " ssl" for e in edits) else []) + [f"include {w}" for w in wanted]
    print(f"→ Attached Jenkins to the nginx server in {path} on port {port}: {', '.join(what)} (backup: {backup})")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--port", type=int, required=True)
    c.add_argument("--mode", choices=["standalone", "shared"], required=True)
    a = sub.add_parser("attach")
    a.add_argument("--port", type=int, required=True)
    a.add_argument("--tls", action="store_true")
    args = ap.parse_args()
    if args.cmd == "check":
        return check(args.port, args.mode)
    return attach(args.port, args.tls)


if __name__ == "__main__":
    sys.exit(main())
