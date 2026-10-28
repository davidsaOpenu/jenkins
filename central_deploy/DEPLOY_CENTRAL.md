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
  log in to, and its **HTTP password** (GerritHub → Settings → HTTP
  Credentials — not the login password). Not a personal account: its SSH
  key ends up in Jenkins, and it is also the Jenkins admin login.
- **Know which port reaches this machine from outside.** The address
  people use (e.g. `192.114.0.189`) may not be on the machine at all — a
  router/NAT in front forwards only some ports to it. Compare
  `hostname -I` with that address; if it isn't listed, ask which public
  ports are forwarded here, or test them (`curl -skI https://<address>:<port>/`
  from outside). `jenkins_url`'s port must be one that arrives. The script
  only opens the machine's own firewall, never a router or cloud firewall.

## 1. Get the code

Clone fresh, as your own user — not inside a Jenkins workspace or any
directory the `jenkins` user can write (the scripts run as root):

    git clone <repo-url> jenkins && cd jenkins

## 2. Write the config

    cp central_deploy/gerrit_central.yml.example central_deploy/gerrit_central.yml
    chmod 600 central_deploy/gerrit_central.yml

Gitignored — never commit it. Fields:

| Field | Required | Meaning |
|---|---|---|
| `gerrit_username` | **yes** | The GerritHub service account (also the Jenkins admin login). |
| `ssh_key_name` | **yes** | File name of its private key in `/root/.ssh/`. Created if missing. |
| `gerrit_http_password` | **yes** | The account's GerritHub HTTP password. Used only to register the key on the account when GerritHub doesn't accept it yet; never reaches Jenkins. A full account credential — keep the file `chmod 600`. Not needed only if the key is already registered (CI's case). |
| `jenkins_url` | no | The address users and agents open. nginx listens on its port (443 for `https`, 80 for `http`, unless the URL names one); a path becomes Jenkins' URL prefix. E.g. `https://ci.example.org`, `https://192.114.0.189:8080/jenkins`. Blank = `https://<auto-detected IP>`. `http` sends passwords and agent secrets unencrypted. |
| `jenkins_internal_port` | no | Jenkins' own port on 127.0.0.1 behind nginx, never reachable from outside. Default 8080 — change it only if 8080 is taken on this machine. |
| `nginx_shared_server` | no | `true`: attach Jenkins to the nginx server **already** listening on `jenkins_url`'s port (shared with other apps — e.g. the only port a NAT forwards here) instead of giving it its own. That server's `listen` gets `ssl` (for `https`) and two `include` lines; nothing else changes (backed up, `nginx -t`-checked). Plain `http://` arriving there is redirected to `https://`. Default `false`. |
| `jenkins_admin_password` | no | Blank: generated once into `/etc/jenkins-dr/admin_password` (root-only) and reused on re-runs. |
| `tls_cert_file`, `tls_key_file` | no | `https` only: a real certificate and key, both or neither. Blank: a self-signed pair for `jenkins_url`'s host is created at `/etc/jenkins-dr/tls/` (see "Browser says Not secure"). |
| `email`, `display_name`, `change_id` | no | All three or none. Only for the end-to-end push test (CI sets them). |

Example — the CSlab server: public address `192.114.0.189`, the router
forwards only ports 80 and 8080 (both to this machine's 8080), and an
existing nginx server on 8080 also serves OpenProject:

```yaml
gerrit_username: "jenkins-osw"
ssh_key_name: "id_jenkins_osw_central"
gerrit_http_password: "<from GerritHub Settings → HTTP Credentials>"
jenkins_url: "https://192.114.0.189:8080/jenkins"
jenkins_internal_port: 9090      # 8080 is nginx's
nginx_shared_server: true        # attach to the existing 8080 server
```

On a plain machine where 443 is reachable, `gerrit_username`,
`ssh_key_name`, `gerrit_http_password` and `jenkins_url:
"https://<address>/jenkins"` are enough.

## 3. Run it

The full disaster-recovery command — replaces an earlier hand-made Jenkins
if there is one, installs, and recreates the jobs from this repo:

    sudo ./central_deploy/setup_central.sh central_deploy/gerrit_central.yml --replace-old-jenkins --with-repo-jobs

Both flags are optional:
- `--replace-old-jenkins` — only needed on a machine that runs (or ran) a
  hand-made Jenkins; harmless otherwise. Without it, leftovers make the
  install stop with a message.
- `--with-repo-jobs` — installs what the real CI jobs need on this
  machine and creates the jobs (see "Jobs"). Without it you get Jenkins
  with just the `jenkins-dr-test` job.

It never prompts, so it can run unattended. Takes several minutes on a
fresh machine. Safe to re-run any time — to reapply config, after fixing a
problem, or to recover.

### What it does

1. Installs prerequisites (Ansible, Python YAML, curl, git, openssl).
2. Creates `/root/.ssh/<ssh_key_name>` if missing, and makes sure GerritHub
   accepts it as `gerrit_username` — registering it with
   `gerrit_http_password` if not.
3. With `--replace-old-jenkins` only (it stops processes and moves data,
   so it never happens implicitly), retires an earlier hand-made Jenkins:
   - stops whatever else listens on `jenkins_internal_port` (and a
     `daemon` supervisor around it);
   - disables a distro `jenkins` service that isn't this install's;
   - moves an old `/var/lib/jenkins` aside to `/var/lib/jenkins.old-<date>`
     (not deleted — old jobs stay there);
   - removes nginx `location` blocks elsewhere (e.g. in
     `/etc/nginx/nginx.conf`) still proxying to that port, which would
     otherwise keep serving the new Jenkins over plain HTTP. Only those
     blocks go — other apps' locations and comments stay.

   Anything this install created carries a marker and is never touched,
   so re-running with the flag is safe.
4. Opens `jenkins_url`'s port in ufw or firewalld, if one is active.
5. Runs `deploy_central_jenkins.sh`: checks `jenkins_url`'s port against
   existing nginx servers; creates the self-signed certificate and/or
   admin password if needed; installs Java 21, Jenkins (systemd service,
   user `jenkins`, bound to 127.0.0.1) with its plugins and JCasC config,
   and nginx in front (its own server, or attached with
   `nginx_shared_server`); then waits until the Gerrit Trigger plugin
   reports it is **connected to GerritHub** — only then prints success.
   With `email`/`display_name`/`change_id` set it also pushes a real
   patchset and waits for the `jenkins-dr-test` job to build it.
   With `--with-repo-jobs`, before Jenkins (re)starts, it also runs each
   job's `1_install_prereqs.sh` — see "What the jobs need".
6. With `--with-repo-jobs` only: runs `create_repo_jobs.sh` — see "Jobs".

Every nginx file it edits is backed up first (`<file>.bak-<timestamp>`),
checked with `nginx -t`, and restored if the check fails.

## 4. After it succeeds

    sudo cat /etc/jenkins-dr/admin_password     # only if jenkins_admin_password was blank

Open `jenkins_url` exactly as configured — **including its port** (e.g.
`https://192.114.0.189:8080/jenkins`; `https://192.114.0.189/jenkins`
without the port means 443) — and log in as `gerrit_username`. Then
onboard students — see `central_deploy/SETUP_STUDENTS.md`. Their agents
need a copy of `/etc/jenkins-dr/tls/jenkins-dr.crt` as `central_ca_cert`
when the certificate is self-signed.

### Browser says "Not secure" (https crossed out)

That's the self-signed certificate: the connection **is** encrypted, but
the browser doesn't know who issued it. Either:

- **Trust it on each computer** that opens Jenkins. Copy
  `/etc/jenkins-dr/tls/jenkins-dr.crt` off the server, check its
  fingerprint matches
  `sudo openssl x509 -in /etc/jenkins-dr/tls/jenkins-dr.crt -noout -fingerprint -sha256`,
  then import it — Windows: double-click → Install Certificate → Local
  Machine → Trusted Root Certification Authorities; macOS: Keychain Access
  → Always Trust; Ubuntu Chrome: Settings → Privacy and security →
  Security → Manage certificates → Authorities → Import. Restart the
  browser.
- **Or use a real certificate**: these are issued for a DNS name, not a
  bare IP — get a name (and a certificate, e.g. from IT or Let's Encrypt)
  for the machine, set `tls_cert_file`/`tls_key_file`, re-run.

## Jobs (`--with-repo-jobs`)

`central_deploy/create_repo_jobs.sh` creates one pipeline job per
`jobs/<name>/Jenkinsfile` (named `<name>`; `jenkins-dr-test` is left to the
JCasC config). It is the disaster-recovery path only — CI's `run.sh` never
runs it. It can also be run on its own on a deployed Jenkins:

    sudo ./central_deploy/create_repo_jobs.sh central_deploy/gerrit_central.yml

- Each job is "Pipeline script from SCM": it reads its Jenkinsfile from
  `https://review.gerrithub.io/davidsaOpenu/jenkins` (`master`) at every
  build, so a merged Jenkinsfile change applies on the next build with no
  redeploy. Only the *list* of jobs comes from your checkout — re-run after
  adding a `jobs/<name>/` folder. (`--repo-url` / `--branch` to override.)
- A pipeline's Gerrit/cron triggers only register when it runs, so each new
  job is **primed**: a build is started and aborted as soon as the pipeline
  has been read, before any stage does work (twice for parameterized jobs,
  so the branch pattern picks up the `GERRIT_BRANCH` default). These show
  as aborted builds #1–#2.
- Re-running is safe: jobs already pointing at the right Jenkinsfile, with
  triggers registered, are left alone.

### What the jobs need

Central's own builds (the daily timer, admin-started ones, and changes
uploaded by the service account) run on the built-in node as the
`jenkins` user — and so does a student's change when their own node
isn't connected (`SETUP_STUDENTS.md`). So the built-in node needs what
the jobs' scripts call.

Each project says what it needs itself, in a **`1_install_prereqs.sh`**
at the root of its repository: run as root, installs for the invoking
user (`SUDO_USER`) — packages, group memberships, per-user setup such as
vagrant plugins. Supported distributions are each script's own choice
(see its `case "$OS_ID"`). With `--with-repo-jobs`, the deploy runs the
one of every job's **main repo** — the GerritHub project its Jenkinsfile's
Gerrit trigger watches, not the extra repos a job merely clones:

| Main repo | Jobs | Runs from |
|---|---|---|
| `jenkins` (this repo) | `jenkins`, plus `periodic-tasks` (no trigger, same needs: docker) | this checkout |
| `simulator` | `simulator-docker-ng-infra` | GerritHub `master` |
| `swiftacular` | `swiftacular`, `swiftacular-podified`, `swiftacular-presentations` | GerritHub `master` |
| `xv6` | `xv6-24.04-vm` — no script; its tools (QEMU, netstat, ssh) come with the simulator's | GerritHub `master` |

The list is read from `jobs/*/Jenkinsfile`, so a new job's repo is picked
up on the next run. Each script runs as root with `SUDO_USER=jenkins`
(see below — not sudo for `jenkins`), from a clone in `/var/cache/central_deploy/repos/<repo>` (root's — a script that
runs as root never comes from a directory `jenkins` can write), before
Jenkins restarts, so the groups it adds are the service's from its first
build. A repo with no `1_install_prereqs.sh` is skipped with a warning; a
script that fails stops the deploy. Re-running is safe as long as the
scripts are (each must be).

This repo's script covers only what its own jobs run: vagrant-libvirt VMs
for `scripts/run.sh` (with the same vagrant plugin pins as swiftacular's,
so both share `jenkins`'s `~/.vagrant.d`), rsync, git-review, Python YAML,
and docker for `periodic-tasks`. Jenkins itself (Java, plugins, nginx)
stays the role's. See `SECURITY_NOTES.md` for what the `docker`,
`libvirt` and `kvm` memberships imply.

**The `jenkins` user never gets sudo from this.** The scripts run as root
— the deploy is run by root or a sudo-capable admin, never by `jenkins` —
and `SUDO_USER=jenkins` only names the account they install *for*. Since
anything that runs as `jenkins` (any build) must be assumed hostile, the
deploy also:

- refuses to run a script that `jenkins` could write, or that sits under
  a directory it could write (a checkout inside a Jenkins workspace);
- logs each script's path, SHA-256 and commit before running it, to
  compare against the reviewed commit — a recovery runs as root whatever
  is on those repos' `master`;
- on every deploy, fails if `jenkins` is in a group outside
  `jenkins_allowed_groups` (default `jenkins docker libvirt kvm`; compared
  by GID, so Ubuntu's `libvirtd` alias passes) or has any sudo rule other
  than the zero-argument `/opt/ci/<script>.sh ""` ones. It reports, never
  fixes: remove the extra group with `gpasswd -d jenkins <group>` (e.g.
  `shadow`, which only the old PAM login needed). As jobs stop needing
  `docker` and `libvirt`, drop them from the list, and the deploy then
  refuses any script that adds them back.

A script must do what it does in the user's home *as that user* (`sudo -u
"$SUDO_USER" …`), never as root: root following a symlink `jenkins`
planted there hands it the target (see `SECURITY_NOTES.md`,
`register_central_key.sh`).

The `jenkins` job's `scripts/run.sh` also needs the zero-argument sudo
rules for `/opt/ci` — installed separately, by the reviewed one-time
`scripts/sudo/deploy_gerrit_multi_user_push.sh`, never by a prereqs
script.

Pipelines that call Jenkins' internal API (e.g. `periodic-tasks`) need
their methods approved once in Manage Jenkins → In-process Script Approval
after their first real run.

## Updating later

Re-run the same `setup_central.sh` command after changing
`gerrit_central.yml`, pulling new changes to `central_deploy/` or
`jobs/jenkins-dr-test/`, or adding a job folder. Other Jenkinsfile edits
need no re-run (those jobs read them from GerritHub); `jenkins-dr-test`'s
is copied from this checkout at deploy time. Nor do changes to `vars/`,
the `osw-ci` library with the approval gate every job loads: Jenkins
reads it from GerritHub master at each build, like the Jenkinsfiles, so
a merged change applies to the next build.

**Once, when the library first arrives:** the deploy is what registers
`osw-ci` in Jenkins, and every Jenkinsfile on master loads it. So deploy
*first* — re-run `setup_central.sh` from a checkout that includes
`vars/` — and only then merge that change to master. The other way
round, every job fails with "No library configured for name osw-ci"
until the deploy. (Until the merge, `jenkins-dr-test` fails instead,
finding no `vars/` on master — harmless.) Re-runs reuse the SSH key,
admin password and certificate, and keep students and their nodes.

A re-run always **restarts Jenkins** — running builds, and builds paused
for approval, are lost. Pick a quiet moment.

Deploy before onboarding students (`SETUP_STUDENTS.md`): students added
to an older deploy log in with whatever permissions it grants until the
re-run.

## Troubleshooting

The scripts stop at the first problem with a `✗` line saying what's wrong:

| Message / symptom | Fix |
|---|---|
| `missing/blank required field(s)` / `must look like` / `was renamed to` | Fix `gerrit_central.yml` as the message says. |
| `GerritHub doesn't accept … gerrit_http_password is blank` | Fill in `gerrit_http_password` (or add the printed public key to the account by hand), re-run. |
| `Registration failed — is gerrit_http_password …` | Use the HTTP password from GerritHub Settings → HTTP Credentials, not the login password. |
| `Port <n> (jenkins_internal_port) is already taken` | An old Jenkins (or nginx) holds it: re-run with `--replace-old-jenkins`, or pick another `jenkins_internal_port`. |
| `An existing nginx server already serves apps on port <n>` | Use a free port in `jenkins_url`, or set `nginx_shared_server: true` to attach Jenkins to that server. |
| `nginx_shared_server: true needs exactly one existing nginx server` | No (or several) nginx servers listen on `jenkins_url`'s port — fix the port, or drop the flag. |
| `nginx still proxies to Jenkins' port` | Re-run with `--replace-old-jenkins` (or run the printed `nginx_jenkins_proxies.py … --apply`). |
| Long `FAILED - RETRYING … ansible.builtin.uri` | Jenkins is still starting (it answers "Jenkins is getting ready" meanwhile); the first start can take minutes. If it gives up: `Jenkins never came up` below. |
| `Jenkins never came up` | Jenkins' own log is printed above it; also `sudo journalctl -u jenkins`. |
| `Gerrit Trigger never connected` | Manage Jenkins → Gerrit Trigger shows the error; also `sudo journalctl -u jenkins`. |
| `Can't log in to Jenkins at …` (jobs) | Deploy first, or the admin password in the config/`/etc/jenkins-dr/admin_password` doesn't match. |
| `… ended before the pipeline started — its Jenkinsfile couldn't be loaded` (jobs) | The printed log says why — usually the repo/branch/`jobs/<name>/Jenkinsfile` isn't reachable or doesn't parse. |
| `⚠ <job>: no triggers registered` (jobs) | That Jenkinsfile defines no `triggers {}` — fine if intended; otherwise check it. |
| Works on the machine, not from outside | `jenkins_url`'s port isn't forwarded to this machine (see "Before you start"). Locally: `curl -skI https://127.0.0.1:<port><prefix>/login -H 'Host: <host>'` should give 200. |
| Browser: "Not secure", https crossed out | Self-signed certificate — see "Browser says Not secure". |

Useful checks: `systemctl status jenkins nginx`, `sudo ss -ltnp`,
`sudo nginx -t`.

## What's where on the machine

| Path | What |
|---|---|
| `/var/lib/jenkins` | Jenkins home (jobs, builds, JCasC in `casc_configs/`). An old one moved aside: `/var/lib/jenkins.old-<date>`. |
| `/etc/systemd/system/jenkins.service` | The Jenkins service (`sudo systemctl restart jenkins`). |
| `/etc/jenkins-dr/admin_password` | Generated admin password (root-only). |
| `/etc/jenkins-dr/tls/` | Self-signed certificate and key. |
| `/root/.ssh/<ssh_key_name>` | The GerritHub SSH key (also copied into Jenkins). |
| `/etc/nginx/snippets/jenkins-dr-*.conf` | Jenkins' nginx location and TLS settings. |
| `/etc/nginx/conf.d/jenkins.conf` | Jenkins' own nginx server (not with `nginx_shared_server`). |
| `/etc/nginx/**.bak-<timestamp>` | Backups of nginx files before each edit — copy one back and `sudo systemctl reload nginx` to undo. |

## Notes

- If the service account is also used by CI's nightly test pushes (as
  `jenkins-osw` is), this Jenkins sees those pushes too and starts
  `jenkins-dr-test` builds for them. They wait for an approval that never
  comes and fail after 15 minutes, without voting — noise, not harm.
- `deploy_central_jenkins.sh` can also be run on its own (same argument)
  on a machine that's already prepared — it is step 5 above.
