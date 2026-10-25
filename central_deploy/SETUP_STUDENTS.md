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

Students need this same file (see step 5).

## Adding students

1. Copy the example config:
   cp central_deploy/students.yaml.example central_deploy/students.yaml

2. Fill in `students.yaml` — for each student:
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

4. Read the output file (`students_credentials.yaml` by default, owner-only)
   — one entry per student, with everything step 5 needs.

5. Send each student, privately and one-to-one (never a group channel),
   only their own entry, plus the certificate file:

   | Send | Value (key in their file entry) | Student uses it for |
   |---|---|---|
   | Jenkins URL | `central_url` | logging in, in a browser |
   | Jenkins user | the entry's name | logging in |
   | Jenkins password | `password` | logging in |
   | `gerrit_owner_username` | the entry's name | `secrets.yml` |
   | `central_url` | `central_url` | `secrets.yml` |
   | `central_agent_name` | `agent_name` (`<name>-vm`) | `secrets.yml` |
   | `central_agent_secret` | `agent_secret` | `secrets.yml` |
   | `jenkins-dr.crt` | the file itself, attached | `secrets.yml`'s `central_ca_cert`: the path where they save it |

   Skip the certificate only if central has a real one (`tls_cert_file`).
   The student follows `student_deploy/CONNECT_AGENT.md` with these. Their
   machine must reach `central_url` (port included) — check from it with
   `curl -s -o /dev/null -w '%{http_code}\n' --cacert jenkins-dr.crt <central_url>/login`
   (must print `200`); the agent connects over that same address, no
   other port.

   A message, one per student:

       Jenkins: <central_url>   user: <name>   password: <password>
       Agent (student_deploy/secrets.yml):
         gerrit_owner_username: "<name>"
         central_url:          "<central_url>"
         central_agent_name:   "<name>-vm"
         central_agent_secret: "<secret>"
         central_ca_cert:      "<where you saved the attached jenkins-dr.crt>"
       Then: sudo ./student_deploy/deploy_agent.sh student_deploy/secrets.yml

   The agent secret lets anyone connect as that student's node, and
   recreating the node does not change it (Jenkins derives it from the
   node name). If one leaks, `./reset_students.sh <name>` — with the node
   gone, the secret connects to nothing. Never share `students.yaml`
   itself — it holds real passwords and is gitignored.

Students can't add nodes themselves: each gets exactly one, `<name>-vm`,
created here — they only connect their own machine to it.

Safe to re-run any time — existing users/nodes are updated, and each
password is reset to the value in `students.yaml`. To add students later,
add them to `students.yaml` and re-run.

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
  agent secret, so their `secrets.yml` keeps working. Both files hold the
  password: keep the `students_*.yaml` names (gitignored) and delete them
  afterwards.

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
