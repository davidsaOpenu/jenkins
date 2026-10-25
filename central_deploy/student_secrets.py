#!/usr/bin/python3
"""Write each student's ready-to-use student_deploy/secrets.yml.

Reads setup_students.sh's credentials file (every student's entry — never
handed out itself) and writes one file per student, <name>.secrets.yml,
holding only that student's values: the four secrets.yml settings, the
central certificate embedded (central_ca_cert_pem — deploy_agent.sh
installs it, no second file to place), and their Jenkins login as a
comment on top. The student saves it as student_deploy/secrets.yml and
runs deploy_agent.sh — nothing to copy by hand.

Usage:
  student_secrets.py <students_credentials.yaml> <out_dir> [<ca_cert.crt>]

<ca_cert.crt>: central's self-signed certificate (a single PEM
certificate). Leave it out when central has a real certificate.
Files are owner-only (0600) in an owner-only directory (0700).
"""
import json
import os
import re
import sys

import yaml

PEM_CERT = re.compile(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", re.S)


def q(value):
    # A JSON string is a valid YAML double-quoted scalar — safe for any
    # character a password or secret may contain.
    return json.dumps(str(value))


def read_cert(path):
    certs = PEM_CERT.findall(open(path).read())
    if len(certs) != 1:
        sys.exit(f"✗ {path}: expected exactly one PEM certificate, found {len(certs)} "
                 "— pass central's own jenkins-dr.crt, not a CA bundle")
    return certs[0]


def render(name, entry, cert):
    lines = [
        f"# {name}'s agent settings — save as student_deploy/secrets.yml, then run:",
        "#   sudo ./student_deploy/deploy_agent.sh student_deploy/secrets.yml",
        "# Keep it private: the agent secret lets anyone connect as your node.",
        "#",
        f"# Your Jenkins login (browser): {entry['central_url']}",
        f"#   user: {name}",
        f"#   password: {entry['password']}",
        "",
        f"gerrit_owner_username: {q(name)}",
        f"central_url: {q(entry['central_url'])}",
        f"central_agent_name: {q(entry['agent_name'])}",
        f"central_agent_secret: {q(entry['agent_secret'])}",
    ]
    if cert:
        lines += ["# Central's certificate — deploy_agent.sh installs it for you.",
                  'central_ca_cert: ""',
                  "central_ca_cert_pem: |"]
        lines += ["  " + line for line in cert.splitlines()]
    else:
        lines += ['central_ca_cert: ""']
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    creds_file, out_dir = sys.argv[1:3]
    cert = read_cert(sys.argv[3]) if len(sys.argv) == 4 else None

    students = yaml.safe_load(open(creds_file)) or {}
    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    os.chmod(out_dir, 0o700)
    for name, entry in students.items():
        path = os.path.join(out_dir, f"{name}.secrets.yml")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(render(str(name), entry, cert))
        # Round-trip check: what deploy_agent.sh will read back.
        back = yaml.safe_load(open(path))
        assert back["central_agent_secret"] == str(entry["agent_secret"]), path
        print(path)


if __name__ == "__main__":
    main()
