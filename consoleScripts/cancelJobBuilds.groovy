import jenkins.model.Jenkins

// Cancels one job's builds on one node: its queue items waiting for that
// node, and its builds running there. Run disableJobs.groovy first so the
// node takes no new ones meanwhile.

def targetJobName = "jenkins"
// Only this node's builds of the job: "built-in", or an agent's name (e.g.
// alice-vm). The job's builds on every other node are left alone.
def targetNodeName = "built-in"
// A build still running this long after a graceful abort (a step stuck on an
// agent, an agent that dropped off) is terminated, then hard-killed.
def forceAfterSeconds = 30

def jenkins = Jenkins.instance
def targetNode = (targetNodeName == "built-in") ? jenkins : jenkins.getNode(targetNodeName)
if (targetNode == null) {
    println "Node '${targetNodeName}' not found."
    return
}

// The nodes a build is running on: whose regular executors hold it (a
// freestyle build) or one of its node blocks (a pipeline). One-off executors
// are left out — every pipeline's own flyweight sits on the built-in node's.
def nodesOf = { build ->
    ([jenkins] + jenkins.nodes).findAll { node ->
        node.toComputer()?.executors?.any { ex ->
            def exe = ex.currentExecutable
            exe != null && (exe == build || exe.parentExecutable == build)
        }
    }.collect { it == jenkins ? 'built-in' : it.nodeName }
}

// 1. Cancel this job's queue items waiting for this node — a running build's
//    node block, or a build of a job that names its node up front. Matched by
//    the job they belong to, exactly (not by display name, which would also
//    catch any job whose name contains this one's), and by the label they
//    wait for matching this node. A build not yet started, with no node
//    picked, isn't this node's: left alone.
def queue = jenkins.queue
for (item in queue.items) {
    def label = item.assignedLabel
    if (item.task.getOwnerTask().getFullName() == targetJobName
            && label != null && label.matches(targetNode.assignedLabels)) {
        println "Canceling queued build item: ${item.task.getFullDisplayName()} (waiting for node: ${label})"
        queue.cancel(item)
    }
}

// 2. Abort this job's builds running on this node
def job = jenkins.getItemByFullName(targetJobName)
if (job != null) {
    def running = job.getBuilds().findAll { it.isBuilding() && targetNodeName in nodesOf(it) }

    for (build in running) {
        println "Aborting active build: ${targetJobName} #${build.number} on node(s): ${nodesOf(build).join(', ')}"
        build.doStop()
    }

    if (running.isEmpty()) {
        println "No active running builds found for job: ${targetJobName} on node: ${targetNodeName}"
    } else {
        // Wait for the aborts to land; escalate on the builds that don't stop.
        // terminate/kill exist on pipeline builds only. A hard kill skips the
        // build's post steps and can leave its processes on the node running.
        def waitFor = { builds ->
            def deadline = System.currentTimeMillis() + forceAfterSeconds * 1000
            while (builds.any { it.isBuilding() } && System.currentTimeMillis() < deadline) {
                sleep(1000)
            }
            builds.findAll { it.isBuilding() }
        }
        def stuck = waitFor(running)
        for (step in ['doTerm', 'doKill']) {
            stuck = stuck.findAll { it.respondsTo(step) }
            if (stuck.isEmpty()) {
                break
            }
            for (build in stuck) {
                println "Still running after ${forceAfterSeconds}s, ${step == 'doTerm' ? 'terminating' : 'hard-killing'}: ${targetJobName} #${build.number} on node(s): ${nodesOf(build).join(', ') ?: 'none'}"
                build."${step}"()
            }
            stuck = waitFor(stuck)
        }
        def left = running.findAll { it.isBuilding() }
        if (left) {
            println "STILL RUNNING — check these by hand: ${left.collect { '#' + it.number }.join(', ')}"
        } else {
            println "All ${running.size()} active build(s) of ${targetJobName} stopped."
        }
    }
} else {
    println "Job '${targetJobName}' not found."
}
