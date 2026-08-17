# Setting up students

1. Copy the example config:
   cp central_deploy/students.yaml.example central_deploy/students.yaml

2. Fill in `students.yaml` — for each student:
   - `name` — their exact GerritHub username (not email). This becomes their
     Jenkins login and their agent node name (`<name>-vm`).
   - `project` — any short label, for your own reference only.
   - `password` — a Jenkins login password for them.

3. Run it:
   cd central_deploy
   ./setup_students.sh

   It asks for the central Jenkins URL, the admin user and the admin
   password. To skip the questions (or from CI), set `JENKINS_URL`,
   `JENKINS_ADMIN_USER` and `JENKINS_ADMIN_PASSWORD` in the environment.

   (Optional custom paths: `./setup_students.sh <config.yaml> <creds_output.yaml>`)

4. Read the output file (`students_credentials.yaml` by default) — it has each
   student's agent name + secret, needed to connect their Jenkins agent.

5. Give each student their own agent name + secret from that file. Never share
   `students.yaml` itself — it holds real passwords and is gitignored.

Safe to re-run any time — existing users/nodes are updated, and each
password is reset to the value in `students.yaml`.

## Removing students

   ./reset_students.sh               # lists the students, then asks which
   ./reset_students.sh alice bob     # removes just these
   ./reset_students.sh all           # removes every student

Same Jenkins URL / admin login questions as above. The list comes from
Jenkins itself, so no old `students.yaml` is needed.
