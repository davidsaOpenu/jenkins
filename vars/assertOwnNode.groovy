// Defense in depth behind buildLabel()'s routing: the first thing inside
// the build stage, before any step touches the node — stops the build
// unless it landed where approvalGate() routed it (OSW_ROUTE):
// - own: the uploader's own node — their "<name>-vm" (setup_students.sh),
//   or the built-in node for central's own identity. GERRIT_OWNER_USERNAME
//   is only trusted on the built-in node, where the controller alone sets
//   it (JCasC's globalNodeProperties) — on an agent it comes from that
//   agent's own service unit;
// - central: the built-in node.
// NODE_NAME is blank (or "master") on the built-in node on some Jenkins
// versions; normalized. Returns the node name; sets OWN_NODE_OK for the
// stage's post steps.
def call() {
    def node = env.NODE_NAME
    if (!node || node == 'master') {
        node = 'built-in'
    }
    def owner = buildOwner()
    def own
    def expected
    switch (env.OSW_ROUTE) {
        case 'central':
            own = (node == 'built-in')
            expected = 'the built-in node'
            break
        case 'own':
            own = (node == 'built-in') ? (owner == env.GERRIT_OWNER_USERNAME)
                                       : (node == owner + '-vm')
            expected = "${owner}'s own node"
            break
        default:
            error('No route decided — approvalGate() must run before the build stage.')
    }
    if (!own) {
        error("Refusing to run: landed on '${node}', which is not ${expected}.")
    }
    env.OWN_NODE_OK = 'yes'
    return node
}
