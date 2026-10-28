import jenkins.model.Jenkins

// --- CONFIGURATION ---
def exemptedJobName = "swiftacular-presentations"
def shouldDisable = true // Set to true to DISABLE, set to false to ENABLE
// ---------------------

def toggleJobState(item, exemption, disableAction) {
    // 1. If it's a folder or multibranch container, recurse into its children
    if (item instanceof com.cloudbees.hudson.plugins.folder.Folder ||
        item instanceof org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject) {
        for (child in item.getItems()) {
            toggleJobState(child, exemption, disableAction)
        }
    }
    // 2. If it's a job that can be disabled (pipeline, freestyle); other
    //    job types have no makeDisabled and are left alone
    else if (item instanceof jenkins.model.ParameterizedJobMixIn.ParameterizedJob) {

        // Check if the job name matches the exemption
        if (item.name == exemption || item.fullName == exemption) {
            println "Skipping (Exempted): ${item.fullName}"
        } else {
            if (disableAction) {
                // Disable logic
                if (item.disabled) {
                    println "Already Disabled: ${item.fullName}"
                } else {
                    item.makeDisabled(true)
                    println "DISABLED: ${item.fullName}"
                }
            } else {
                // Enable logic
                if (!item.disabled) {
                    println "Already Enabled: ${item.fullName}"
                } else {
                    item.makeDisabled(false)
                    println "ENABLED: ${item.fullName}"
                }
            }
        }
    }
}

// Start traversal from the Jenkins root level
println "Starting mass job updates... Mode: ${shouldDisable ? 'DISABLING' : 'ENABLING'}"
for (item in Jenkins.instance.getItems()) {
    toggleJobState(item, exemptedJobName, shouldDisable)
}
println "Job toggle sequence complete."
