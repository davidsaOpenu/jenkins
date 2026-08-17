# Setting up students

1. Copy the example config:
   cp central_deploy/students.yaml.example central_deploy/students.yaml

2. Fill in `students.yaml`:
   - `central_url`, `admin_user`, `admin_password` — the real central Jenkins and its admin login.
   - For each student:
     - `name` — their exact GerritHub username (not email). This becomes their
       Jenkins login and their agent node name (`<name>-vm`).
     - `project` — any short label, for your own reference only.
     - `password` — a Jenkins login password for them.

3. Run it:
   cd central_deploy
   ./setup_students.sh

   (Optional custom paths: `./setup_students.sh <config.yaml> <creds_output.yaml>`)

4. Read the output file (`students_credentials.yaml` by default) — it has each
   student's agent name + secret, needed to connect their Jenkins agent.

5. Give each student their own agent name + secret from that file. Never share
   `students.yaml` itself — it holds real passwords and is gitignored.

Safe to re-run any time — existing users/nodes are skipped, not recreated.
