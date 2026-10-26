#!/usr/bin/env python3
"""Emails each student their own students_secrets/<name>.secrets.yml.

Usage:
  ./send_student_secrets.py --from <you@gmail.com>                 # dry run
  ./send_student_secrets.py --from <you@gmail.com> --send          # send
      [--emails emails.txt] [--secrets-dir students_secrets]
      [--only <username>]... [--force] [--attach-as yml|txt]
      [--smtp smtp.gmail.com:587] [--smtp-user <login>]

Each email in the list is resolved to its GerritHub username live (exact,
case-insensitive email match, same as find_gerrit_user.sh), and only that
username's file goes to that address — one recipient, one file, per
message. Anything unresolvable, ambiguous or mismatched is skipped and
reported, never guessed.

Without --send nothing is sent: it prints the plan. Sends through
Gmail (smtp.gmail.com:587, STARTTLS) as --from; another provider's
server can be given with --smtp. The password comes from $SMTP_PASSWORD
or a prompt and is never stored — for Gmail it must be an app password
(needs 2-Step Verification: myaccount.google.com/apppasswords), Google
refuses the normal one. Sent files are logged (time, user, email, file hash — no contents)
to <secrets-dir>/sent.log; a re-run skips a student whose current file
was already sent to that address, unless --force. A regenerated file
(new password) has a new hash, so it is sent again.

Exits 1 if any student was skipped or failed.
"""
import argparse
import datetime
import getpass
import hashlib
import json
import os
import re
import smtplib
import ssl
import sys
import urllib.parse
import urllib.request
from email.message import EmailMessage

import yaml

GERRIT_URL = os.environ.get("GERRIT_URL", "https://review.gerrithub.io")
EMAIL = re.compile(r"[\w.+'-]+@[\w-]+(?:\.[\w-]+)+")
HERE = os.path.dirname(os.path.abspath(__file__))

BODY = """\
Hi {username},

Attached: your Jenkins agent settings for the course CI ({url}).

1. Save the attachment as student_deploy/secrets.yml in your clone of
   https://review.gerrithub.io/davidsaOpenu/jenkins{rename}
2. On the machine that will run your agent:
     sudo ./student_deploy/deploy_agent.sh student_deploy/secrets.yml
3. Follow student_deploy/CONNECT_AGENT.md — it explains approving builds
   of your own Gerrit changes on your node.

Your Jenkins login (user and password) is in the comment at the top of
the file.

The file is for you only: its secret lets anyone connect as your node.
Don't forward or share it, and delete this email once your agent is
running. If it leaks, tell me and I'll issue a new one.
"""


def read_emails(path):
    out, seen = [], set()
    with open(path) as f:
        for line in f:
            if line.lstrip().startswith("#"):
                continue
            found = EMAIL.findall(line)
            if not found and line.strip():
                print(f"SKIPPED line (no email address): {line.strip()!r}", file=sys.stderr)
            for e in found:
                if e.lower() not in seen:
                    seen.add(e.lower())
                    out.append(e)
    return out


def lookup_username(email):
    """GerritHub username registered with exactly this email, or (None, why)."""
    q = urllib.parse.urlencode({"suggest": "", "q": email, "n": 10})
    with urllib.request.urlopen(f"{GERRIT_URL}/accounts/?{q}", timeout=20) as r:
        text = r.read().decode()
    if text.startswith(")]}"):  # Gerrit's anti-XSSI prefix line
        text = text[text.index("\n") + 1:]
    hits = [a for a in json.loads(text) if a.get("email", "").lower() == email.lower()]
    if not hits:
        return None, "no GerritHub account with this email"
    if len(hits) > 1:
        return None, "several GerritHub accounts with this email"
    if not hits[0].get("username"):
        return None, "GerritHub account has no username"
    return hits[0]["username"], ""


def check_secrets_file(path, username):
    """The file's contents must be this student's, or (None, why)."""
    if not os.path.isfile(path):
        return None, f"no file {os.path.basename(path)} (run ./setup_students.sh?)"
    with open(path, "rb") as f:
        raw = f.read()
    try:
        d = yaml.safe_load(raw)
    except yaml.YAMLError as e:
        return None, f"{path}: not valid YAML ({e.__class__.__name__})"
    if not isinstance(d, dict) or d.get("gerrit_owner_username") != username \
            or d.get("central_agent_name") != f"{username}-vm" \
            or not d.get("central_agent_secret"):
        return None, f"{path}: is not {username}'s secrets file"
    return (raw, d.get("central_url", "")), ""


def load_log(path):
    sent = set()
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 4:
                    sent.add((parts[1], parts[2].lower(), parts[3]))
    return sent


def append_log(path, username, email, digest):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a") as f:
        now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        f.write(f"{now}\t{username}\t{email}\t{digest}\n")


def build_message(sender, email, username, raw, url, attach_as):
    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = email
    msg["Subject"] = f"Your Jenkins agent settings ({username})"
    rename = "" if attach_as == "yml" else \
        "\n   (it is attached as .txt so mail filters let it through — rename it)"
    msg.set_content(BODY.format(username=username, url=url or "central Jenkins", rename=rename))
    name = f"{username}.secrets.{attach_as}"
    msg.add_attachment(raw, maintype="text", subtype="plain" if attach_as == "txt" else "yaml",
                       filename=name)
    return msg


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--from", dest="sender", required=True, help="your address (the From:)")
    p.add_argument("--emails", default=os.path.join(HERE, "emails.txt"))
    p.add_argument("--secrets-dir", default=os.path.join(HERE, "students_secrets"))
    p.add_argument("--only", action="append", default=[], metavar="USERNAME",
                   help="only these students (repeatable)")
    p.add_argument("--send", action="store_true", help="really send (default: dry run)")
    p.add_argument("--force", action="store_true", help="re-send even if already sent")
    p.add_argument("--attach-as", choices=["yml", "txt"], default="yml")
    p.add_argument("--smtp", default="smtp.gmail.com:587", help="host:port (STARTTLS)")
    p.add_argument("--smtp-user", help="SMTP login (default: --from)")
    a = p.parse_args(argv)

    if not EMAIL.fullmatch(a.sender):
        p.error(f"--from {a.sender!r} is not an email address")
    log_path = os.path.join(a.secrets_dir, "sent.log")
    already = load_log(log_path)
    only = {u.lower() for u in a.only}

    plan, problems = [], 0
    for email in read_emails(a.emails):
        try:
            username, why = lookup_username(email)
        except OSError as e:
            sys.exit(f"ERROR: cannot reach {GERRIT_URL} ({e})")
        if not username:
            print(f"SKIP {email}: {why}", file=sys.stderr)
            problems += 1
            continue
        if only and username.lower() not in only:
            continue
        path = os.path.join(a.secrets_dir, f"{username}.secrets.yml")
        content, why = check_secrets_file(path, username)
        if not content:
            print(f"SKIP {email} ({username}): {why}", file=sys.stderr)
            problems += 1
            continue
        raw, url = content
        digest = hashlib.sha256(raw).hexdigest()
        if (username, email.lower(), digest) in already and not a.force:
            print(f"already sent: {username} -> {email} (this exact file; --force to resend)")
            continue
        plan.append((email, username, path, raw, url, digest))
    for u in only - {x[1].lower() for x in plan}:
        if not any(u == k[0].lower() for k in already):
            print(f"NOTE: --only {u}: not in {a.emails}, or skipped above", file=sys.stderr)

    if not plan:
        print("Nothing to send.")
        return 1 if problems else 0
    print(f"\n{'SENDING' if a.send else 'DRY RUN — would send'} ({len(plan)}):")
    for email, username, path, *_ in plan:
        print(f"  {email:32} <- {os.path.relpath(path)}")
    if not a.send:
        print("\nNothing sent. Add --send to send these.")
        return 1 if problems else 0

    host, _, port = a.smtp.rpartition(":")
    hint = "a Google app password, not your normal one" if host == "smtp.gmail.com" \
        else "your mail password"
    password = os.environ.get("SMTP_PASSWORD") or \
        getpass.getpass(f"SMTP password for {a.smtp_user or a.sender} ({hint}): ")
    failed = 0
    with smtplib.SMTP(host, int(port), timeout=30) as s:
        s.starttls(context=ssl.create_default_context())
        try:
            s.login(a.smtp_user or a.sender, password)
        except smtplib.SMTPAuthenticationError as e:
            sys.exit(f"ERROR: {host} refused the login ({e.smtp_code} "
                     f"{e.smtp_error.decode(errors='replace')[:200]}).\n"
                     "Gmail: use an app password (myaccount.google.com/apppasswords, "
                     "needs 2-Step Verification), not your normal password.")
        del password
        for email, username, path, raw, url, digest in plan:
            msg = build_message(a.sender, email, username, raw, url, a.attach_as)
            try:
                # Envelope recipient is exactly this one address.
                s.send_message(msg, from_addr=a.sender, to_addrs=[email])
            except smtplib.SMTPException as e:
                print(f"FAILED {email} ({username}): {e}", file=sys.stderr)
                failed += 1
                continue
            append_log(log_path, username, email, digest)
            print(f"sent: {username} -> {email}")
    return 1 if (problems or failed) else 0


if __name__ == "__main__":
    sys.exit(main())
