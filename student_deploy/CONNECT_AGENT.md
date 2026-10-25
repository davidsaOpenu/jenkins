# Connecting your agent to central Jenkins

1. Your instructor sends you (after running `setup_students.sh` for you):
   - your Jenkins login: URL, user, password;
   - `central_url` — the same Jenkins URL, port and path included;
   - `central_agent_name` (e.g. `alice-vm`) and `central_agent_secret`;
   - usually a certificate file, `jenkins-dr.crt` — save it on the
     machine that will run your agent.

   Keep the secret and password private: the secret lets anyone connect
   as your node.

   Check that machine reaches central — this must print `200`:

       curl -s -o /dev/null -w '%{http_code}\n' --cacert jenkins-dr.crt <central_url>/login

   (without `--cacert …` if you got no certificate file). Anything else:
   the address or port isn't reachable from there — tell your instructor.

2. Copy the example config:
   cp student_deploy/secrets.yml.example student_deploy/secrets.yml

3. Fill in `secrets.yml`:
   - `gerrit_owner_username` — your own GerritHub username (same as your
     Jenkins user).
   - `central_url`, `central_agent_name`, `central_agent_secret` — from step 1.
   - `central_ca_cert` — the full path where you saved `jenkins-dr.crt`
     (e.g. `/home/alice/jenkins-dr.crt`). Leave it blank only if you got
     no certificate file.

4. Run it:
   sudo ./student_deploy/deploy_agent.sh student_deploy/secrets.yml

5. Confirm it's running:
   systemctl status jenkins-agent

## Approving builds on your node

Your node runs only builds of patch sets **you** uploaded to Gerrit —
never another student's. Even those don't start on their own: each build
pauses at an **Approval** step and waits for you.

1. Log in to `central_url` with your Jenkins user and password.
2. Open the paused build (its job page, or the Gerrit change's link). The
   console shows exactly what is waiting: project, change, patch set,
   commit — check it is the code you mean to run.
3. Click **Run it on my node**, or **Abort**. Nobody else can click it.
   No answer within 15 minutes and the build fails.

To run it again, comment `recheck` on the change in Gerrit — you can't
start or stop builds from Jenkins itself. You can read every build's log,
on every node.

Keep the Jenkins password your instructor gave you: it never expires, and
if your instructor re-runs the student setup, any password you set yourself
is replaced by that one. Forgot it? Ask your instructor — there is no
reset email.

## Supported systems

Any Linux that uses systemd. The script installs what it needs:
- Ansible — automatically on dnf, apt, zypper and pacman systems. On
  anything else, install Ansible yourself first.
- Java — automatically on the Red Hat, Debian/Ubuntu, SUSE and Arch
  families (Java 21; Java 25 on Fedora, which no longer ships 21). On
  anything else, or a release without that package, install Java 21 or
  newer yourself first; an existing one is used as-is.

macOS and Linux without systemd are not supported by the script.

Keep `secrets.yml` private — it holds a real credential and is gitignored.
Safe to re-run if you need to reinstall.
