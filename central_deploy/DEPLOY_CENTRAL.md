# Installing central Jenkins (disaster recovery)

This installs central Jenkins on the machine you run it on — a real server
or a VM. It is the same script, command and config shape that CI's
`scripts/run.sh` runs inside its `jenkins-01` VM every night, so a passing
CI run means this exact install works.

1. You need a GerritHub account with an SSH key registered to it
   (Settings > SSH Keys). Jenkins' Gerrit Trigger plugin connects as this
   account to listen for GerritHub events; it is also the Jenkins admin
   login. Use a dedicated service account, not a personal one: its private
   key is copied into Jenkins. Put the private key in **`/root/.ssh/`** on
   this machine (the script runs as root and always looks there, however
   `sudo` is configured).

2. Copy the example config:
   cp central_deploy/gerrit_central.yml.example central_deploy/gerrit_central.yml

3. Fill in `gerrit_central.yml`. Only two fields are required:
   - `gerrit_username` — the GerritHub username.
   - `ssh_key_name` — filename under `/root/.ssh/` of its private key.

   Everything else is optional:
   - `jenkins_admin_password` — blank generates one, kept in
     `/etc/jenkins-dr/admin_password` (root-only, reused on re-runs).
   - `jenkins_url` — the full address users and agents use, e.g.
     `https://ci.example.org` or `https://192.114.0.189:9090/jenkins`.
     nginx listens on the URL's port — 443 for `https`, 80 for `http` when
     none is given (`http` is unencrypted: logins and agent secrets travel
     in clear text); a path becomes Jenkins' URL prefix.
     nginx in front is the only way in — Jenkins itself listens on
     localhost only. Blank means `https://<auto-detected IP>`.
   - `jenkins_http_port` — the port Jenkins listens on behind nginx,
     on 127.0.0.1 only (default 8080). Change it only if 8080 is taken.
   - `tls_cert_file`, `tls_key_file` — https only: a real certificate and
     key. Blank creates a self-signed one at
     `/etc/jenkins-dr/tls/jenkins-dr.crt`; students then need a copy.
   - `email`, `display_name`, `change_id` — only for the end-to-end push
     test (see step 4). Set all three or none.

4. Run it:
   sudo ./central_deploy/deploy_central_jenkins.sh central_deploy/gerrit_central.yml

   This installs Jenkins, applies the JCasC config and the Gerrit Trigger
   configuration, and only prints success once the plugin is actually
   connected to GerritHub. If `email`/`display_name`/`change_id` are set it
   also pushes a real patchset and waits for the `jenkins-dr-test` job to
   build it — the same end-to-end check CI runs.

   On a machine that already ran a hand-made Jenkins, the script first
   checks for leftovers and stops if it finds any:
   - another process on `jenkins_http_port` (e.g. an old Jenkins) — stop it;
   - an nginx `location` elsewhere (e.g. in `/etc/nginx/nginx.conf`) still
     proxying to that port — it would keep serving the new Jenkins over
     plain HTTP. Remove just those blocks (other apps' locations are kept;
     every changed file is backed up and `nginx -t`-checked, restored on
     failure):

         sudo ./central_deploy/nginx_jenkins_proxies.py --port <jenkins_http_port> --apply

   Also move an old `/var/lib/jenkins` aside first (e.g. one created by a
   Jenkins run as root) — the new Jenkins runs as the `jenkins` user.

5. Once it succeeds, onboard your students — see `central_deploy/SETUP_STUDENTS.md`.

Keep `gerrit_central.yml` private — it holds a real password and is gitignored.
Safe to re-run any time to reapply config or recover after a failure.

## Supported systems

- **CentOS Stream 9 / RHEL / Rocky** (dnf) — EPEL is added automatically.
- **Ubuntu 22.04** (apt).

The script installs its own prerequisites (Ansible, Python YAML, curl, git,
openssl) with whichever of the two the machine has, then the Ansible role
installs Java 21, Jenkins and nginx the same way. Anything else (no dnf or
apt) is refused up front.
