# Setting up students

Deploy (or update) central first — `DEPLOY_CENTRAL.md` — and run this from
a checkout of the same version, so students never get an older deploy's
permissions and the name check below applies.

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
   password. To skip the questions (or from CI), set `JENKINS_URL`,
   `JENKINS_ADMIN_USER` and `JENKINS_ADMIN_PASSWORD` in the environment.

   If central uses a self-signed certificate, first run
   `export CURL_CA_BUNDLE=<path to its .crt>` — and give that file to the
   students too (their `central_ca_cert`).

   (Optional custom paths: `./setup_students.sh <config.yaml> <creds_output.yaml>`)

4. Read the output file (`students_credentials.yaml` by default, owner-only)
   — it has each student's Jenkins password and agent name + secret.

5. Send each student, privately and one-to-one (never a group channel),
   only their own:
   - Jenkins URL, user (their `name`) and password — to log in, watch
     builds and approve their own;
   - `central_url`, `central_agent_name` and `central_agent_secret` — to
     connect their node (`student_deploy/CONNECT_AGENT.md`);
   - with a self-signed certificate: a copy of it, as `central_ca_cert`.

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
