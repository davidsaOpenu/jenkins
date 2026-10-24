# Installing central Jenkins (disaster recovery)

This installs central Jenkins on the machine you run it on — a real server
or a VM. It is the same script, command and config shape that CI's
`scripts/run.sh` runs inside its `jenkins-01` VM every night, so a passing
CI run means this exact install works.

1. You need a real GerritHub account with an SSH key already registered to
   it (Settings > SSH Keys) — this account becomes both the Jenkins-Gerrit
   identity and the Jenkins admin login. Use a dedicated service account,
   not a personal one: its private key is copied into Jenkins. Put the
   matching private key in **`/root/.ssh/`** on this machine (the script
   runs as root and always looks there, however `sudo` is configured).

2. Copy the example config:
   cp central_deploy/gerrit_central.yml.example central_deploy/gerrit_central.yml

3. Fill in `gerrit_central.yml`:
   - `gerrit_username` — your GerritHub username.
   - `jenkins_admin_password` — password you want for this identity's Jenkins login.
   - `ssh_key_name` — filename under `/root/.ssh/` of your registered private key.
   - `email`, `display_name` — your GerritHub account's registered email and a display name.
   - `change_id` — a fixed Change-Id on a permanent Gerrit change reserved for
     verification pushes (reused every run, never opens a new change).
   - `tls_cert_file`, `tls_key_file` — paths on this machine of the HTTPS
     certificate and its private key. Jenkins is served only over HTTPS
     (port 443, through nginx), so port 443 must be reachable by students.
     Leave both blank to get a self-signed certificate, created at
     `/etc/jenkins-dr/tls/jenkins-dr.crt` (and reused on re-runs). Students
     then need a copy of that `.crt` file.

4. Run it:
   sudo ./central_deploy/deploy_central_jenkins.sh central_deploy/gerrit_central.yml

   This installs Jenkins, applies the JCasC config, wires up the Gerrit
   Trigger, and automatically verifies it end-to-end with a real Gerrit
   push. It only prints success if that verification actually passes.

5. Once it succeeds, onboard your students — see `central_deploy/SETUP_STUDENTS.md`.

Keep `gerrit_central.yml` private — it holds a real password and is gitignored.
Safe to re-run any time to reapply config or recover after a failure.
