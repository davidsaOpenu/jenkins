// A newer patch set supersedes the older ones — on its own node only.
// Call right after approvalGate(), still in the Approval stage with no
// node allocated: nodes have one executor, so a build already waiting
// for the node could never stop the build holding it.
//
// Aborts every build of this job that is for the same Gerrit change at a
// lower patch set and holds, or is queued for, an executor on the node
// this build is routed to (buildLabel()). Builds on any other node are
// left alone, as are rechecks of the same patch set and central's own
// (timer, admin) builds. An aborted build's post steps still run, so its
// node gets cleaned up as usual.
def call() {
    def change = env.GERRIT_CHANGE_NUMBER
    def patchset = env.GERRIT_PATCHSET_NUMBER
    if (!change || !patchset) {
        return
    }
    def label = buildLabel()
    def aborted = abortOlder(env.JOB_NAME, change, patchset.toInteger(), label,
                             "superseded by patch set ${patchset} (build #${env.BUILD_NUMBER})")
    if (aborted) {
        echo "Aborted on this build's node (${label}), superseded by patch set ${patchset}: ${aborted.join(', ')}"
    } else {
        echo "No older patch set of change ${change} running on this build's node (${label})."
    }
}

// Jenkins' own objects stay in this method: they can't be kept across a
// pipeline step. Nodes are matched against their current labels, as in
// approvalGate's nodeConnected().
@NonCPS
private List<String> abortOlder(String jobName, String change, int patchset,
                                String label, String why) {
    def jenkins = jenkins.model.Jenkins.get()
    def wanted = jenkins.getLabel(label)
    def nodes = ([jenkins] + jenkins.getNodes()).findAll { n ->
        wanted.matches(n.getAssignedLabels())
    }
    def runs = [] as Set
    // Holding an executor there: a node block's placeholder, whose parent
    // is the run. The run's own flyweight executor (on the built-in node,
    // wherever the build runs) has no parent, so it never counts.
    nodes.each { n ->
        n.toComputer()?.getAllExecutors()?.each { ex ->
            def run = ex.getCurrentExecutable()?.getParentExecutable()
            if (run) {
                runs << run
            }
        }
    }
    // Queued for an executor there. An item with no label could go to any
    // node — not provably this one, so left alone.
    jenkins.getQueue().getItems().each { item ->
        def l = item.getAssignedLabel()
        def run = item.task.getOwnerExecutable()
        if (l && run && nodes.any { n -> l.matches(n.getAssignedLabels()) }) {
            runs << run
        }
    }
    def aborted = []
    runs.each { run ->
        if (!(run instanceof org.jenkinsci.plugins.workflow.job.WorkflowRun)
                || run.getParent().getFullName() != jobName || !run.isBuilding()) {
            return
        }
        def values = run.getAction(hudson.model.ParametersAction)?.getAllParameters()
        def runChange = values?.find { it.getName() == 'GERRIT_CHANGE_NUMBER' }?.getValue()
        def runPatchset = values?.find { it.getName() == 'GERRIT_PATCHSET_NUMBER' }?.getValue()
        if (runChange != change || !(runPatchset ==~ /\d+/) || runPatchset.toInteger() >= patchset) {
            return
        }
        run.setDescription([run.getDescription(), why].findAll().join(' — '))
        run.getExecutor()?.interrupt(hudson.model.Result.ABORTED)
        aborted << "#${run.getNumber()} (patch set ${runPatchset})".toString()
    }
    return aborted
}
