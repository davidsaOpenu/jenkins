# consoleScripts

Groovy scripts for Jenkins' **Script Console**, plus `jenkins_console.py`,
which runs the same scripts from the command line. One set of files serves
both ways:

- **Browser only:** open *Manage Jenkins → Script Console*, paste a script,
  edit its `CONFIGURATION` lines, click *Run*.
- **Command line:** `jenkins_console.py run <script> name=value …` sends the
  file to the same engine (`/scriptText`), with your values in place of
  the defaults. The file itself is never changed.

Both need a Jenkins **admin**: the script console can do anything Jenkins
can.

| Script | Does | Settings (default) |
|---|---|---|
| `disableJobs.groovy` | Disables every job (folders included) except one; or re-enables them | `exemptedJobName` (`"swiftacular-presentations"`), `shouldDisable` (`true`; `false` = enable) |
| `cancelJobBuilds.groovy` | Cancels one job's builds on one node: its queue items waiting for that node, and its builds running there. A build that doesn't stop after an abort is terminated, then hard-killed | `targetJobName` (`"jenkins"`), `targetNodeName` (`"built-in"`, or an agent such as `alice-vm`), `forceAfterSeconds` (`30`) |

## Command line

Needs only `python3` (standard library, nothing to install).

### Connecting

    export JENKINS_URL=https://jenkins.example      # or --url
    export JENKINS_USER=admin                       # or --user
    export JENKINS_CACERT=/etc/jenkins-dr/tls/jenkins-dr.crt   # or --cacert; self-signed Jenkins only

The password comes from `JENKINS_TOKEN`, or is asked for (without echo)
when that is unset — never from the command line, where every local user
could read it with `ps`. An **API token** is better than the password:
*your user (top right) → Security → API Token → Add new token*.

### Examples

List the scripts and their settings:

    consoleScripts/jenkins_console.py list

See exactly what would run, without running it:

    consoleScripts/jenkins_console.py run disableJobs exemptedJobName=jenkins --dry-run

Disable every job except `jenkins`, then enable them all again later:

    consoleScripts/jenkins_console.py run disableJobs exemptedJobName=jenkins
    consoleScripts/jenkins_console.py run disableJobs shouldDisable=false

Cancel the `jenkins` job's builds on the built-in node (the defaults):

    consoleScripts/jenkins_console.py run cancelJobBuilds

Cancel `xv6-24.04-vm`'s builds on a student's node, giving them a minute to
stop before forcing:

    consoleScripts/jenkins_console.py run cancelJobBuilds \
        targetJobName=xv6-24.04-vm targetNodeName=alice-vm forceAfterSeconds=60

Before maintenance on the built-in node — no job starts new builds (no job
is named `none`, so none is exempted), then `swiftacular`'s builds there
are stopped:

    consoleScripts/jenkins_console.py run disableJobs exemptedJobName=none
    consoleScripts/jenkins_console.py run cancelJobBuilds targetJobName=swiftacular

A script from elsewhere works too, settings and all:

    consoleScripts/jenkins_console.py run /path/to/other.groovy

### Settings

A **setting** is a top-level `def name = <literal>` line: a string, `true` /
`false`, or a whole number. `name=value` must keep the default's kind —
`shouldDisable=maybe` and `forceAfterSeconds=abc` are refused, as is a name
the script doesn't have (the error lists the ones it has). Code lines such
as `def jenkins = Jenkins.instance` are not settings.

### Exit status

| Code | Meaning |
|---|---|
| 0 | The script ran to its end |
| 1 | It threw (the stack trace is printed) or stopped early |
| 2 | Usage error, or Jenkins unreachable / refused the login (401/403: wrong user or token, or not an admin) |

Jenkins answers HTTP 200 even when a script throws; the tool appends a
marker line to the script and checks it came back.

## Adding a script

Keep it pasteable: a plain Groovy script with its settings as top-level
`def name = <literal>` lines near the top (under a `// --- CONFIGURATION ---`
comment, as in `disableJobs.groovy`), and `println` for its output. It is
then usable both ways with nothing else to do — `list` shows it and `run`
can set its settings.

## Before running

- `--dry-run` first: the script runs as Jenkins itself, with no undo.
- `cancelJobBuilds`' hard kill (after `forceAfterSeconds`, pipeline builds
  only) skips the build's `post` steps and can leave its processes running
  on the node; remove `'doKill'` from the script to never use it.
- A disabled job is disabled on every node — Jenkins has no per-node
  disable.
