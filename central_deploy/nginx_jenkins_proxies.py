#!/usr/bin/python3
"""Find (and optionally remove) nginx `location` blocks that proxy to
Jenkins' localhost port from anywhere other than this install's own site.

A hand-made setup typically has something like

    location /jenkins/ { proxy_pass http://localhost:9090/jenkins/; ... }

inside an existing server block (often shared with other apps). Left in
place after deploy_central_jenkins.sh, it keeps serving the new Jenkins
over that old listener — plain HTTP, bypassing the HTTPS site. Only the
matching location blocks are removed; the rest of the file, comments and
other apps' locations are left byte-for-byte as they were.

Usage (as root):
  nginx_jenkins_proxies.py --port 9090            # report only (default)
  nginx_jenkins_proxies.py --port 9090 --apply    # remove, nginx -t, reload

Exit codes: 0 nothing found (or removed successfully), 3 found in report
mode, 1 error (with --apply, every file is restored before exiting).
"""
import argparse
import datetime
import glob
import os
import re
import shutil
import subprocess
import sys

NGINX_DIR = "/etc/nginx"
# This install's own site — never touched.
OWN_SITE = os.path.join(NGINX_DIR, "conf.d", "jenkins.conf")
CANDIDATE_GLOBS = [
    "nginx.conf",
    "conf.d/*.conf",
    "default.d/*.conf",   # RHEL family
    "sites-enabled/*",    # Debian family
]
LOCAL_HOSTS = r"(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])"


def tokenize(text):
    """Yields (kind, value, start, end) for nginx config text: kind is
    'word', '{', '}' or ';'. Comments are skipped, quotes respected."""
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif c == "#":
            while i < n and text[i] != "\n":
                i += 1
        elif c in "{};":
            yield c, c, i, i + 1
            i += 1
        elif c in "'\"":
            start, quote = i, c
            i += 1
            while i < n and text[i] != quote:
                i += 2 if text[i] == "\\" else 1
            i += 1
            yield "word", text[start + 1:i - 1], start, i
        else:
            start = i
            while i < n and not text[i].isspace() and text[i] not in "{};#":
                i += 1
            yield "word", text[start:i], start, i


def parse(text):
    """Returns a list of directives: dicts with name, args, start, end and,
    for blocks, children."""
    tokens = list(tokenize(text))
    pos = 0

    def parse_block():
        nonlocal pos
        items = []
        words = []
        while pos < len(tokens):
            kind, value, start, end = tokens[pos]
            pos += 1
            if kind == "word":
                words.append((value, start))
            elif kind == ";":
                if words:
                    items.append({"name": words[0][0], "args": [w for w, _ in words[1:]],
                                  "start": words[0][1], "end": end})
                words = []
            elif kind == "{":
                if not words:
                    raise ValueError(f"block without a name at offset {start}")
                children, close_end = parse_block()
                items.append({"name": words[0][0], "args": [w for w, _ in words[1:]],
                              "start": words[0][1], "end": close_end, "children": children})
                words = []
            elif kind == "}":
                return items, end
        return items, len(text)

    items, _ = parse_block()
    return items


def proxies_to_port(block, port):
    target = re.compile(rf"^https?://{LOCAL_HOSTS}:{port}(?:/|$)")
    for child in block.get("children", []):
        if child["name"] == "proxy_pass" and child["args"] and target.match(child["args"][0]):
            return child["args"][0]
        if "children" in child:
            found = proxies_to_port(child, port)
            if found:
                return found
    return None


def find_locations(items, port, out):
    for item in items:
        if "children" not in item:
            continue
        if item["name"] == "location":
            target = proxies_to_port(item, port)
            if target:
                out.append((item, target))
                continue
        find_locations(item["children"], port, out)
    return out


def removal_span(text, block):
    """Whole lines when the block owns them; otherwise just the block."""
    start, end = block["start"], block["end"]
    line_start = text.rfind("\n", 0, start) + 1
    if text[line_start:start].strip() == "":
        start = line_start
    line_end = text.find("\n", end)
    line_end = len(text) if line_end == -1 else line_end + 1
    if text[end:line_end].strip() == "":
        end = line_end
    return start, end


def candidate_files():
    seen = set()
    for pattern in CANDIDATE_GLOBS:
        for path in sorted(glob.glob(os.path.join(NGINX_DIR, pattern))):
            real = os.path.realpath(path)
            if real == os.path.realpath(OWN_SITE) or real in seen or not os.path.isfile(real):
                continue
            seen.add(real)
            yield real


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--port", type=int, required=True, help="Jenkins' localhost port (jenkins_internal_port)")
    ap.add_argument("--apply", action="store_true", help="remove the blocks, nginx -t, reload")
    args = ap.parse_args()

    findings = {}
    for path in candidate_files():
        text = open(path).read()
        try:
            hits = find_locations(parse(text), args.port, [])
        except ValueError as e:
            print(f"✗ Could not parse {path}: {e}", file=sys.stderr)
            return 1
        if hits:
            findings[path] = (text, hits)

    if not findings:
        return 0

    for path, (text, hits) in findings.items():
        for block, target in hits:
            line = text.count("\n", 0, block["start"]) + 1
            print(f"  {path}:{line}: location {' '.join(block['args'])} -> {target}", file=sys.stderr)

    if not args.apply:
        print(f"✗ nginx still proxies to Jenkins' port {args.port} outside {OWN_SITE} —"
              f" it would serve the new Jenkins over that listener, bypassing HTTPS.\n"
              f"  Remove those location blocks (other locations are kept):\n"
              f"    sudo {os.path.abspath(__file__)} --port {args.port} --apply", file=sys.stderr)
        return 3

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backups = {}
    for path, (text, hits) in findings.items():
        backup = f"{path}.bak-{stamp}"
        shutil.copy2(path, backup)
        backups[path] = backup
        new = text
        for block, _ in sorted(hits, key=lambda h: h[0]["start"], reverse=True):
            start, end = removal_span(new, block)
            new = new[:start] + new[end:]
        with open(path, "w") as f:
            f.write(new)
        print(f"→ Removed {len(hits)} location block(s) from {path} (backup: {backup})")

    check = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
    if check.returncode != 0:
        for path, backup in backups.items():
            shutil.copy2(backup, path)
        print("✗ nginx -t failed after the edit — every file restored from its backup:\n"
              + check.stderr, file=sys.stderr)
        return 1
    if subprocess.run(["systemctl", "is-active", "--quiet", "nginx"]).returncode == 0:
        subprocess.run(["systemctl", "reload", "nginx"], check=True)
        print("→ nginx reloaded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
