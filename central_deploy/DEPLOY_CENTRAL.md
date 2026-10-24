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
   - `tls_cert_file`, `tls_key_file` — a real HTTPS certificate and key.
     Jenkins is served only over HTTPS (port 443, through nginx), so port
     443 must be reachable by students. Blank creates a self-signed one at
     `/etc/jenkins-dr/tls/jenkins-dr.crt`; students then need a copy.
   - `jenkins_public_ip` — blank auto-detects it.
   - `email`, `display_name`, `change_id` — only for the end-to-end push
     test (see step 4). Set all three or none.

4. Run it:
   sudo ./central_deploy/deploy_central_jenkins.sh central_deploy/gerrit_central.yml

   This installs Jenkins, applies the JCasC config and the Gerrit Trigger
   configuration, and only prints success once the plugin is actually
   connected to GerritHub. If `email`/`display_name`/`change_id` are set it
   also pushes a real patchset and waits for the `jenkins-dr-test` job to
   build it — the same end-to-end check CI runs.

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
