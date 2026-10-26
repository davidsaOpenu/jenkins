// A job's Approval stage body. Run with no node allocated (agent none) —
// nothing touches anyone's node until the uploader approves.
//
// A Gerrit build belongs to the uploader of the patch set that triggered
// it. Decides where it runs (OSW_ROUTE, read by buildLabel() and
// assertOwnNode()):
// - uploader's node connected: asks "run or abort", then runs on that
//   node (own). Only the uploader's Run counts — anyone else's is
//   refused and the question stays open; Abort works for anyone logged
//   in. Unanswered for 15 minutes: aborted;
// - not connected (or no node at all): nothing is asked; the build joins
//   the regular queue on the built-in node (central), like any build.
//
// allowCentralBuilds: let central's own builds (timer, admin) through
// without approval, to the built-in node; otherwise only Gerrit builds
// run at all.
def call(Map args = [:]) {
    boolean allowCentralBuilds = args.allowCentralBuilds ?: false
    env.OSW_ROUTE = ''
    if (!env.GERRIT_EVENT_TYPE && allowCentralBuilds) {
        echo 'No Gerrit change (timer or admin-started build) — runs on the built-in node, no approval needed.'
        env.OSW_ROUTE = 'central'
        return
    }
    def uploader = env.GERRIT_PATCHSET_UPLOADER_USERNAME
    if (!uploader) {
        error('Manual builds are not supported — this job only runs from a real Gerrit push or a "recheck" comment.')
    }
    def label = buildLabel.ownLabel(uploader)
    if (!nodeConnected(label)) {
        toBuiltIn("${uploader}'s node is not connected to Jenkins")
        return
    }
    // Exactly what the click lets run, so it's an informed
    // one — the prompt sits right below this in the console.
    echo """PAUSED — waiting for ${uploader} to approve this build.
  Job:       ${env.JOB_NAME}
  Event:     ${env.GERRIT_EVENT_TYPE}
  Project:   ${env.GERRIT_PROJECT} (branch ${env.GERRIT_BRANCH})
  Change:    ${env.GERRIT_CHANGE_NUMBER} — ${env.GERRIT_CHANGE_SUBJECT}
             ${env.GERRIT_CHANGE_URL}
  Patch set: ${env.GERRIT_PATCHSET_NUMBER}, uploaded by ${uploader}
  Commit:    ${env.GERRIT_PATCHSET_REVISION}
  Runs on:   ${uploader}'s own node, nobody else's
Only ${uploader} can run it; anyone logged in can abort it."""
    def approver = null
    // submitter: who may click at all — the uploader, plus every logged-in
    // user ("authenticated"), so anyone can Abort. Run is then checked
    // here against the real authenticated clicker (an admin passes any
    // submitter list, so this check is what keeps Run the uploader's).
    timeout(time: 15, unit: 'MINUTES') {
        while (approver != uploader) {
            approver = input message: "${uploader}: run change ${env.GERRIT_CHANGE_NUMBER} patch set ${env.GERRIT_PATCHSET_NUMBER} " +
                                      "(commit ${env.GERRIT_PATCHSET_REVISION}) on your own node? " +
                                      "Only approve code you have reviewed — it runs with your agent's privileges. " +
                                      "(Run: ${uploader} only. Abort: anyone.)",
                             ok: 'Run it on my node',
                             submitter: "${uploader},authenticated",
                             submitterParameter: 'APPROVER'
            if (approver != uploader) {
                echo "REJECTED — ${approver} is not ${uploader}; only ${uploader} can run it. Still waiting."
            }
        }
    }
    echo "APPROVED by ${approver} — resuming build."
    // It may have dropped off while the question was open.
    if (!nodeConnected(label)) {
        toBuiltIn("${uploader}'s node disconnected after approval")
        return
    }
    env.OSW_ROUTE = 'own'
}

// Whether a node carrying this label — the uploader's own
// (buildLabel.ownLabel()) — is connected right now. Matches each node
// (built-in included) against its current labels: Label.getNodes() and
// Label.contains() read a cache that can lag a label change, and a stale
// "not connected" would send the build to the built-in node unapproved.
// Jenkins' own objects stay in this method: they can't be kept across a
// pipeline step.
@NonCPS
private boolean nodeConnected(String label) {
    def jenkins = jenkins.model.Jenkins.get()
    def wanted = jenkins.getLabel(label)
    return ([jenkins] + jenkins.getNodes()).any { n ->
        wanted.matches(n.getAssignedLabels()) && n.toComputer()?.isOnline()
    }
}

// No own node to run on: the build goes to the regular queue on the
// built-in node, unapproved — as every build did before own nodes.
private void toBuiltIn(String why) {
    echo "${why} — no approval asked; queued on the built-in node like any other build."
    env.OSW_ROUTE = 'central'
}
