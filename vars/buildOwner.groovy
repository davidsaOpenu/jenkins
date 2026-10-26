// Whose build this is: the patch set's uploader for a Gerrit-triggered
// build; null for central's own (a timer, or started by an admin —
// students have no Job/Build).
def call() {
    if (!env.GERRIT_EVENT_TYPE) {
        return null
    }
    def uploader = env.GERRIT_PATCHSET_UPLOADER_USERNAME
    if (!uploader) {
        error('No Gerrit uploader on this build — refusing to pick a node.')
    }
    return uploader
}
