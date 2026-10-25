# Connecting your agent to central Jenkins

1. Your instructor sends you one file, `<name>.secrets.yml`. On the
   machine that will run your agent, in your clone of this repo, save it
   as `student_deploy/secrets.yml` — exactly as received, nothing to fill
   in. It holds your agent's settings, central's certificate, and your
   Jenkins login (URL, user, password) in the comment at its top.

   Keep it private: its secret lets anyone connect as your node.

2. Check that machine reaches central — this must print `200`
   (`central_url` is in the file):

       curl -sk -o /dev/null -w '%{http_code}\n' <central_url>/login

   (`-k` only because this check doesn't use the certificate; the deploy
   does.) Anything else: that address or port isn't reachable from
   there — tell your instructor.

3. Run it:
   sudo ./student_deploy/deploy_agent.sh student_deploy/secrets.yml

4. Confirm it's running:
   systemctl status jenkins-agent

(No file from your instructor, just values? Copy
`student_deploy/secrets.yml.example` to `student_deploy/secrets.yml` and
fill it in — its comments say what goes where.)

## Approving builds on your node

Your node runs only builds of patch sets **you** uploaded to Gerrit —
never another student's. Even those don't start on their own: each build
pauses at an **Approval** step and waits for you.

1. Log in to `central_url` with your Jenkins user and password (top of
   your `secrets.yml`).
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
