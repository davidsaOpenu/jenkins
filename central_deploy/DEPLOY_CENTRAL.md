# Installing central Jenkins (disaster recovery)

One command takes a machine to a running central Jenkins:
`central_deploy/setup_central.sh`. CI's `scripts/run.sh` runs the same
command, with the same config shape, inside its `jenkins-01` VM every
night — so a passing CI run means this exact install works.

What you end up with:

```
browsers / agents ──HTTPS (jenkins_url)──▶ nginx ──HTTP──▶ Jenkins on 127.0.0.1:<jenkins_internal_port>
                                                            runs as user `jenkins`, config from code (JCasC)
                                                            Gerrit Trigger ──SSH──▶ review.gerrithub.io:29418
```

Jenkins is never reachable directly — nginx is the only way in. The Gerrit
Trigger plugin listens to GerritHub events and starts jobs per their
Jenkinsfiles.

## Before you start

- **Ubuntu 22.04** (apt) or **CentOS Stream 9 / RHEL / Rocky** (dnf), and
  `sudo`. The script installs everything else.
- A **GerritHub service account** for Jenkins (e.g. `jenkins-osw`) you can
  log in to. Not a personal account: its SSH key ends up in Jenkins, and it
  is also the Jenkins admin login.
- If the machine sits behind a cloud/network firewall, allow the port in
  `jenkins_url` there (443 for `https://…` with no port). The script only
  opens the machine's own firewall.

## 1. Get the code

Clone fresh, as your own user — not inside a Jenkins workspace or any
directory the `jenkins` user can write (the script runs as root):

    git clone <repo-url> jenkins && cd jenkins

## 2. Write the config

    cp central_deploy/gerrit_central.yml.example central_deploy/gerrit_central.yml
    chmod 600 central_deploy/gerrit_central.yml

Gitignored — never commit it. Fields:

| Field | Required | Meaning |
|---|---|---|
| `gerrit_username` | **yes** | The GerritHub service account (also the Jenkins admin login). |
| `ssh_key_name` | **yes** | File name of its private key in `/root/.ssh/`. Created if missing. |
| `jenkins_url` | no | The address users and agents open, e.g. `https://192.114.0.189/jenkins`. nginx listens on its port (443 for `https`, 80 for `http`, unless the URL names one); a path becomes Jenkins' URL prefix. Blank = `https://<auto-detected IP>`. `http` sends passwords and agent secrets unencrypted. |
| `jenkins_internal_port` | no | Jenkins' own port on 127.0.0.1 behind nginx, never reachable from outside. Default 8080 — change it only if 8080 is taken on this machine. |
| `jenkins_admin_password` | no | Blank: generated once into `/etc/jenkins-dr/admin_password` (root-only) and reused on re-runs. |
| `tls_cert_file`, `tls_key_file` | no | `https` only: a real certificate and key, both or neither. Blank: a self-signed pair for `jenkins_url`'s host is created at `/etc/jenkins-dr/tls/`. |
| `email`, `display_name`, `change_id` | no | All three or none. Only for the end-to-end push test (CI sets them). |

Example — HTTPS under `/jenkins`, on a machine where nginx already holds
8080:

```yaml
gerrit_username: "jenkins-osw"
ssh_key_name: "id_jenkins_osw_central"
jenkins_url: "https://192.114.0.189/jenkins"
jenkins_internal_port: 9090
```

## 3. Run it

On a fresh machine:

    sudo ./central_deploy/setup_central.sh central_deploy/gerrit_central.yml

On a machine that already runs (or ran) a hand-made Jenkins, add
`--replace-old-jenkins` — see below:

    sudo ./central_deploy/setup_central.sh central_deploy/gerrit_central.yml --replace-old-jenkins

Run it in a terminal the first time: if GerritHub doesn't know the SSH key
yet, it shows the public key and asks for the account's GerritHub **HTTP
password** (Settings → HTTP Credentials) to register it for you — typed
hidden, used once, never stored. Or add the key yourself at
https://review.gerrithub.io/settings/#SSHKeys and just press Enter.

Takes several minutes on a fresh machine. Safe to re-run any time — to
reapply config, after fixing a problem, or to recover.

### What it does

1. Installs prerequisites (Ansible, Python YAML, curl, git, openssl).
2. Creates `/root/.ssh/<ssh_key_name>` if missing, and makes sure GerritHub
   accepts it as `gerrit_username` (registering it as above if not).
3. With `--replace-old-jenkins` only — it stops processes and moves data,
   so it never happens implicitly. Retires an earlier hand-made Jenkins:
   - stops whatever else listens on `jenkins_internal_port` (and a
     `daemon` supervisor around it);
   - disables a distro `jenkins` service that isn't this install's;
   - moves an old `/var/lib/jenkins` aside to `/var/lib/jenkins.old-<date>`
     (not deleted — old jobs stay there);
   - removes nginx `location` blocks elsewhere (e.g. in
     `/etc/nginx/nginx.conf`) still proxying to that port, which would
     otherwise keep serving the new Jenkins over plain HTTP. Only those
     blocks go — other apps' locations and comments stay; each changed file
     is backed up and `nginx -t`-checked, all restored if it fails.

   Anything this install created carries a marker and is never touched,
   so re-running with the flag is safe. Without the flag, leftovers make
   the install stop with a message instead.
4. Opens `jenkins_url`'s port in ufw or firewalld, if one is active.
5. Runs `deploy_central_jenkins.sh`: creates the self-signed certificate
   and/or admin password if needed; installs Java 21, Jenkins (systemd
   service, user `jenkins`, bound to 127.0.0.1) with its plugins and JCasC
   config, and nginx in front; then waits until the Gerrit Trigger plugin
   reports it is **connected to GerritHub** — only then prints success.
   With `email`/`display_name`/`change_id` set it also pushes a real
   patchset and waits for the `jenkins-dr-test` job to build it.

## 4. After it succeeds

    sudo cat /etc/jenkins-dr/admin_password     # only if jenkins_admin_password was blank

Open `jenkins_url` and log in as `gerrit_username` with that password.
With a self-signed certificate the browser warns once; students' agents
need a copy of `/etc/jenkins-dr/tls/jenkins-dr.crt` as their
`central_ca_cert`. Then onboard students — see
`central_deploy/SETUP_STUDENTS.md`.

## Troubleshooting

The scripts stop at the first problem with a `✗` line saying what's wrong:

| Message | Fix |
|---|---|
| `missing/blank required field(s)` / `must look like` / `was renamed to` | Fix `gerrit_central.yml` as the message says. |
| `GerritHub doesn't accept this key … then re-run` | Not run in a terminal and the key isn't registered: add the printed public key to the account, re-run. |
| `Registration failed — wrong HTTP password?` | Use the HTTP password from GerritHub Settings → HTTP Credentials (not the login password). |
| `Port <n> (jenkins_internal_port) is already taken` | An old Jenkins (or nginx) holds it: re-run with `--replace-old-jenkins`, or pick another `jenkins_internal_port`. |
| `nginx still proxies to Jenkins' port` | Re-run with `--replace-old-jenkins` (or run the printed `nginx_jenkins_proxies.py … --apply`). |
| `Jenkins never came up` | Jenkins' own log is printed above it; also `sudo journalctl -u jenkins`. |
| `Gerrit Trigger never connected` | Manage Jenkins → Gerrit Trigger shows the error; also `sudo journalctl -u jenkins`. |

Useful checks: `systemctl status jenkins nginx`, `sudo ss -ltnp`,
`sudo nginx -t`. The nginx site is `/etc/nginx/conf.d/jenkins.conf`.

## Notes

- If the service account is also used by CI's nightly test pushes (as
  `jenkins-osw` is), this Jenkins sees those pushes too and starts
  `jenkins-dr-test` builds for them. They wait for an approval that never
  comes and fail after ~30 minutes, without voting — noise, not harm.
- `deploy_central_jenkins.sh` can also be run on its own (same argument)
  on a machine that's already prepared — it is step 5 above.
