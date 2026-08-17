# Installing central Jenkins (disaster recovery)

1. You need a real GerritHub account with an SSH key already registered to
   it (Settings > SSH Keys) — this account becomes both the Jenkins-Gerrit
   identity and the Jenkins admin login. Make sure the matching private key
   is on this machine under `~/.ssh/`.

2. Copy the example config:
   cp central_deploy/gerrit_central.yml.example central_deploy/gerrit_central.yml

3. Fill in `gerrit_central.yml`:
   - `gerrit_username` — your GerritHub username.
   - `jenkins_admin_password` — password you want for this identity's Jenkins login.
   - `ssh_key_name` — filename under `~/.ssh/` of your registered private key.
   - `email`, `display_name` — your GerritHub account's registered email and a display name.
   - `change_id` — a fixed Change-Id on a permanent Gerrit change reserved for
     verification pushes (reused every run, never opens a new change).

4. Run it:
   sudo ./central_deploy/deploy_central_jenkins.sh central_deploy/gerrit_central.yml

   This installs Jenkins, applies the JCasC config, wires up the Gerrit
   Trigger, and automatically verifies it end-to-end with a real Gerrit
   push. It only prints success if that verification actually passes.

5. Once it succeeds, onboard your students — see `central_deploy/SETUP_STUDENTS.md`.

Keep `gerrit_central.yml` private — it holds a real password and is gitignored.
Safe to re-run any time to reapply config or recover after a failure.
