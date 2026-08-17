# Connecting your agent to central Jenkins

1. Ask your instructor for these 3 values (they get them by running
   `setup_students.sh` for you):
   - `central_url`
   - `central_agent_name` (e.g. `alice-vm`)
   - `central_agent_secret`

2. Copy the example config:
   cp student_deploy/secrets.yml.example student_deploy/secrets.yml

3. Fill in `secrets.yml`:
   - `gerrit_owner_username` — your own GerritHub username.
   - `central_url`, `central_agent_name`, `central_agent_secret` — from step 1.

4. Run it:
   sudo ./student_deploy/deploy_agent.sh student_deploy/secrets.yml

5. Confirm it's running:
   systemctl status jenkins-agent

Keep `secrets.yml` private — it holds a real credential and is gitignored.
Safe to re-run if you need to reinstall.
