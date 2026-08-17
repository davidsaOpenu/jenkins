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
   - `central_ca_cert` — only if the instructor also gave you a certificate
     file: the path where you saved it. Otherwise leave it blank.

4. Run it:
   sudo ./student_deploy/deploy_agent.sh student_deploy/secrets.yml

5. Confirm it's running:
   systemctl status jenkins-agent

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
