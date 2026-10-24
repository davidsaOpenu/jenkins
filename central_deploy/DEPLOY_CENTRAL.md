# Installing central Jenkins (disaster recovery)

`deploy_central_jenkins.sh` installs central Jenkins on the machine you run
it on — a real server or a VM. CI's `scripts/run.sh` runs the same script,
command and config shape inside its `jenkins-01` VM every night, so a
passing CI run means this exact install works.

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

- A supported OS: **Ubuntu 22.04** (apt) or **CentOS Stream 9 / RHEL /
  Rocky** (dnf). The script installs everything else itself.
- Root on the machine (`sudo`).
- A **GerritHub service account** for Jenkins (e.g. `jenkins-osw`) that
  you can log in to, to register an SSH key. Not a personal account: its
  private key is copied into Jenkins, and it becomes the Jenkins admin
  login.
- The port in `jenkins_url` (443 for `https://…` with no port) free on the
  machine and open in its firewall.

## 1. Get the code

Clone the repo fresh, as your own user — not inside a Jenkins workspace or
any directory the `jenkins` user can write (the script runs as root):

    git clone <repo-url> jenkins && cd jenkins

All commands below run from this directory.

## 2. Clean up an old Jenkins (only if this machine had one)

Skip this on a fresh machine. On a machine that ran Jenkins by hand, the
script refuses to start until these are dealt with — doing them first saves
a round trip.

**a. Stop the old Jenkins** and anything that would restart it. Find what
holds its port, then stop it the way it was started:

    sudo ss -ltnp | grep <old-port>                                         # who is listening
    sudo daemon --name=jenkins --pidfile=/var/log/jenkins/jenkins.pid --stop   # if started with `daemon`
    sudo systemctl disable --now jenkins 2>/dev/null                        # if a distro service exists
    sudo ss -ltnp | grep <old-port>                                         # must print nothing now

**b. Move its data aside.** The new Jenkins runs as the `jenkins` user and
starts clean; an old home (often root-owned, with a different login setup
and plugins) would break it. Old jobs stay available in the copy:

    sudo mv /var/lib/jenkins /var/lib/jenkins.old-$(date +%F)

**c. Remove old nginx proxies to Jenkins' port.** A hand-made setup usually
has a `location /jenkins/ { proxy_pass http://localhost:<port>/…; }` inside
an existing nginx server. Left in place, it would keep serving the new
Jenkins over plain HTTP, bypassing HTTPS. Report first, then remove — only
those location blocks go; other apps' locations and comments are kept,
each changed file is backed up, and everything is restored if `nginx -t`
fails:

    sudo ./central_deploy/nginx_jenkins_proxies.py --port <jenkins_internal_port>           # report
    sudo ./central_deploy/nginx_jenkins_proxies.py --port <jenkins_internal_port> --apply   # remove

## 3. Create and register the GerritHub SSH key

The script always reads the key from **`/root/.ssh/`**, however `sudo` is
configured:

    sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/<key-name> -C "jenkins@$(hostname)"
    sudo cat /root/.ssh/<key-name>.pub

Log in to https://review.gerrithub.io as the service account → Settings →
SSH Keys → add that `.pub` line. Check it works (accept the host key when
asked):

    sudo ssh -i /root/.ssh/<key-name> -p 29418 <gerrit-username>@review.gerrithub.io gerrit version

## 4. Write the config

    cp central_deploy/gerrit_central.yml.example central_deploy/gerrit_central.yml
    chmod 600 central_deploy/gerrit_central.yml

It is gitignored — never commit it. Fields:

| Field | Required | Meaning |
|---|---|---|
| `gerrit_username` | **yes** | The GerritHub service account (also the Jenkins admin login). |
| `ssh_key_name` | **yes** | File name of its private key in `/root/.ssh/`. |
| `jenkins_url` | no | The address users and agents open, e.g. `https://192.114.0.189/jenkins`. nginx listens on its port (443 for `https`, 80 for `http`, unless the URL names one); a path becomes Jenkins' URL prefix. Blank = `https://<auto-detected IP>`. `http` sends passwords and agent secrets unencrypted. |
| `jenkins_internal_port` | no | Jenkins' own port on 127.0.0.1 behind nginx, never reachable from outside. Default 8080 — change it only if 8080 is taken on this machine. |
| `jenkins_admin_password` | no | Blank: generated once into `/etc/jenkins-dr/admin_password` (root-only) and reused on re-runs. |
| `tls_cert_file`, `tls_key_file` | no | `https` only: a real certificate and key, both or neither. Blank: a self-signed pair for `jenkins_url`'s host is created at `/etc/jenkins-dr/tls/`. |
| `email`, `display_name`, `change_id` | no | All three or none. Only for the end-to-end push test (CI sets them); see step 6. |

Example — HTTPS under `/jenkins`, on a machine where nginx already holds
8080:

```yaml
gerrit_username: "jenkins-osw"
ssh_key_name: "id_jenkins_osw_central"
jenkins_url: "https://192.114.0.189/jenkins"
jenkins_internal_port: 9090
```

## 5. Open the firewall

For the port in `jenkins_url` (443 here), if a firewall is active:

    sudo ufw allow 443/tcp                                                      # Ubuntu
    sudo firewall-cmd --permanent --add-service=https && sudo firewall-cmd --reload   # CentOS/RHEL

## 6. Run it

    sudo ./central_deploy/deploy_central_jenkins.sh central_deploy/gerrit_central.yml

In order, it:
1. installs its prerequisites (Ansible, Python YAML, curl, git, openssl);
2. validates the config and checks the key authenticates to GerritHub;
3. checks for leftovers from an old Jenkins (step 2) and stops if any;
4. creates the self-signed certificate and/or admin password if needed;
5. installs Java 21, Jenkins (as a systemd service, user `jenkins`, bound
   to 127.0.0.1) with its plugins and JCasC config, and nginx in front;
6. waits until the Gerrit Trigger plugin reports it is **connected to
   GerritHub** — only then prints success. With `email`/`display_name`/
   `change_id` set it also pushes a real patchset and waits for the
   `jenkins-dr-test` job to build it, the same end-to-end check CI runs.

Takes several minutes on a fresh machine. Safe to re-run any time — to
reapply config, after fixing a problem, or to recover.

## 7. After it succeeds

    sudo cat /etc/jenkins-dr/admin_password     # only if jenkins_admin_password was blank

Open `jenkins_url` and log in as `gerrit_username` with that password.
With a self-signed certificate the browser warns once; students' agents
need a copy of `/etc/jenkins-dr/tls/jenkins-dr.crt` as their
`central_ca_cert`. Then onboard students — see
`central_deploy/SETUP_STUDENTS.md`.

## Troubleshooting

The script stops at the first problem with a `✗` line saying what's wrong:

| Message | Fix |
|---|---|
| `missing/blank required field(s)` / `must look like` / `was renamed to` | Fix `gerrit_central.yml` as the message says. |
| `… not found — place the private key …` | The key isn't in `/root/.ssh/` under `ssh_key_name` (step 3). |
| `SSH auth as '<user>' failed` | The `.pub` isn't registered on that GerritHub account, or the username is wrong. |
| `Port <n> (jenkins_internal_port) is already taken` | An old Jenkins (or nginx) holds it — step 2a, or pick another `jenkins_internal_port`. |
| `nginx still proxies to Jenkins' port` | Step 2c — run the printed `--apply` command. |
| `Jenkins never came up` | Jenkins' own log is printed above it; also `sudo journalctl -u jenkins`. |
| `Gerrit Trigger never connected` | Manage Jenkins → Gerrit Trigger shows the error; also `sudo journalctl -u jenkins`. |

Useful checks: `systemctl status jenkins nginx`, `sudo ss -ltnp`,
`sudo nginx -t`. The nginx site is `/etc/nginx/conf.d/jenkins.conf`.

## Notes

- If the service account is also used by CI's nightly test pushes (as
  `jenkins-osw` is), this Jenkins sees those pushes too and starts
  `jenkins-dr-test` builds for them. They wait for an approval that never
  comes and fail after ~30 minutes, without voting — noise, not harm.
- Supported systems: **Ubuntu 22.04** (apt), **CentOS Stream 9 / RHEL /
  Rocky** (dnf; EPEL added automatically). Anything else is refused up
  front.
