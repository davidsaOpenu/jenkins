# Setting up students

Deploy (or update) central first — `DEPLOY_CENTRAL.md` — and run this from
a checkout of the same version, so students never get an older deploy's
permissions and the name check below applies.

## Before you start: trust central's certificate

Unless `gerrit_central.yml` named a real certificate (`tls_cert_file`),
the deploy made a self-signed one, and both `setup_students.sh` and
`reset_students.sh` refuse to talk to Jenkins until you tell them to trust
it (they stop with "certificate isn't trusted"). In every new shell,
before running either script:

    export CURL_CA_BUNDLE=/etc/jenkins-dr/tls/jenkins-dr.crt

That file is on the central machine (made by the deploy, readable by
everyone; its `.key` next to it is not, and never leaves the machine).
Running the scripts from another machine? Copy the `.crt` there first
(e.g. `scp central:/etc/jenkins-dr/tls/jenkins-dr.crt .`) and export that
path instead. Check it works — this must print `200`:

    curl -s -o /dev/null -w '%{http_code}\n' <jenkins_url>/login

Students need this same certificate — `setup_students.sh` embeds it in
the file each one is sent (step 4), so there's nothing extra to send. On
the central machine it finds it by itself; elsewhere, also
`export CENTRAL_CA_CERT=<your copy of jenkins-dr.crt>`.

## Adding students

1. Make `students.yaml`. Easiest, from a list of the students' emails —
   one per line in a file, any format with the address in it
   (`Jane Doe <jane@x.org>`, CSV rows, ...); lines starting with `#` are
   skipped:

       cd central_deploy
       ./find_gerrit_user.sh -f emails.txt --update students.yaml

   (`emails*.txt` here is gitignored.)

   For each email it finds the GerritHub account (exact match, no login
   needed) and appends that student — their username as `name`, project
   `all` (or `--project <label>`), a random password — unless they're
   already in the file. It creates the file (owner-only) if missing, and
   never prints the passwords. Emails can also go on the command line:
   `./find_gerrit_user.sh --update students.yaml a@x.org b@y.org`. Without
   `--update` it only prints the usernames.

   An email it can't match is reported (`NOT FOUND`: the student has never
   signed in to GerritHub, or uses another email there) and the rest are
   still added — ask that student for their username, or to sign in once,
   and re-run. Safe to re-run with the whole list any time.

   Or by hand: `cp students.yaml.example students.yaml`.

2. Check / fill in `students.yaml` — for each student:
   - `name` — their exact GerritHub username (not email). This becomes their
     Jenkins login and their agent node name (`<name>-vm`). Letters, digits
     and single inner hyphens only, not ending in `-vm` — the script refuses
     any name that could route one student's builds to another's node.
   - `project` — any short label, for your own reference only.
   - `password` — a Jenkins login password for them.

3. Run it:
   cd central_deploy
   ./setup_students.sh

   It asks for the central Jenkins URL, the admin user and the admin
   password. The URL is `jenkins_url` exactly as in `gerrit_central.yml`,
   port and path included (e.g. `https://192.114.0.189:8080/jenkins`) —
   it is also what students get as `central_url`. To skip the questions
   (or from CI), set `JENKINS_URL`, `JENKINS_ADMIN_USER` and
   `JENKINS_ADMIN_PASSWORD` in the environment.

   (Optional custom paths: `./setup_students.sh <config.yaml> <creds_output.yaml>`)

4. It writes two things next to each other (all owner-only, gitignored):
   - `students_credentials.yaml` — every student, for your records.
     Never send it: it holds everyone's password and agent secret.
   - `students_secrets/<name>.secrets.yml` — one per student, ready to
     use as their `student_deploy/secrets.yml`: their agent settings, the
     certificate embedded, and their Jenkins login (URL, user, password)
     as a comment on top. The script lists them at the end.

   If it says "No certificate embedded" but central uses the self-signed
   one, set `CENTRAL_CA_CERT` (see "Before you start") and re-run.

5. Send each student **their own** `students_secrets/<name>.secrets.yml`
   — that one file, nothing else — privately and one-to-one (never a
   group channel). For example:

       Attached: your Jenkins agent settings. Save it as
       student_deploy/secrets.yml in your clone of this repo, then run
         sudo ./student_deploy/deploy_agent.sh student_deploy/secrets.yml
       and follow student_deploy/CONNECT_AGENT.md. Your Jenkins login is
       at the top of the file. Keep the file private.

   Their machine must reach `central_url` (port included): the agent
   downloads from and connects to that one address, no other port.

   The agent secret lets anyone connect as that student's node, and
   recreating the node does not change it (Jenkins derives it from the
   node name). If one leaks, `./reset_students.sh <name>` — with the node
   gone, the secret connects to nothing. Never share `students.yaml` or
   `students_credentials.yaml` — they hold everyone's passwords.

Students can't add nodes themselves: each gets exactly one, `<name>-vm`,
created here — they only connect their own machine to it.

Safe to re-run any time — existing users/nodes are updated, and each
password is reset to the value in `students.yaml`. To add students later,
add them to `students.yaml` (step 1) and re-run.

## Passwords

The password in `students.yaml` stays until someone changes it — Jenkins
never asks for a change on first login, and it never expires. There is no
"forgot password" email either: a forgotten password comes back to you.

- **Students can change their own** (their name, top right → Security,
  or `<jenkins_url>/me/account`). But the next `setup_students.sh` run
  sets it back to the one in `students.yaml`. Simplest: ask students to
  keep the one you gave them, so `students.yaml` always has it.
- **Forgotten password:** look it up in `students.yaml` (or
  `students_credentials.yaml`) and send it again.
- **Reset one student only** (new password, or one they changed and
  forgot): put just that student in a file of its own, with the new
  password, and run the script on it — with its own output file, so the
  full `students_credentials.yaml` isn't overwritten:

      ./setup_students.sh students_alice.yaml students_credentials_alice.yaml

  Then update their entry in `students.yaml` too, or the next full run
  puts the old password back. Their node is re-created with the same
  agent secret, so their `secrets.yml` keeps working — just tell them the
  new password (their regenerated `students_secrets/<name>.secrets.yml`
  has it too). Both one-off files hold the password: keep the
  `students_*.yaml` names (gitignored) and delete them afterwards.

## What a student can do

Logged in, every student is **read-only** on all of Jenkins: every job,
every running and finished build, and every build's console log — on every
node, theirs or not. Nothing else: they cannot start, retrigger, stop or
configure builds, nor browse workspaces.

Builds start only from Gerrit — a push, or a `recheck` comment on the
change. A build of a change runs only on the node of the student who
uploaded that patch set, never on anyone else's, and only after that
student approves it: the build pauses (holding no node) at an Approval
step showing the change, patch set and commit, which only the uploader
can approve. Builds left unapproved fail after 15 minutes.

The permissions are in `roles/jenkins/templates/jenkins.yaml.j2`
(`authorizationStrategy`); the routing and approval in
`jobs/jenkins-dr-test/Jenkinsfile`.

## Removing students

   ./reset_students.sh               # lists the students, then asks which
   ./reset_students.sh alice bob     # removes just these
   ./reset_students.sh all           # removes every student

Same Jenkins URL / admin login questions as above. The list comes from
Jenkins itself, so no old `students.yaml` is needed.
