// The label a job's build stage runs on (`agent { label buildLabel() }`),
// as approvalGate() decided (OSW_ROUTE): the uploader's own node, or the
// built-in node — for central's own builds, and for uploaders whose node
// isn't connected. Which node builds this IS the routing decision —
// assertOwnNode() only double-checks it.
def call() {
    switch (env.OSW_ROUTE) {
        case 'central':
            return 'built-in'
        case 'own':
            return ownLabel(buildOwner())
        default:
            error('No route decided — approvalGate() must run before the build stage.')
    }
}

// The label of a user's own node. Same derivation as jenkins.yaml.j2's
// built-in-node label and setup_students.sh.
def ownLabel(String username) {
    if (!username) {
        error('No Gerrit uploader on this build — refusing to pick a node.')
    }
    return username.replaceAll(/[^A-Za-z0-9]+/, '-')
}
