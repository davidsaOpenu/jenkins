#!/usr/bin/env bash
# Every job but periodic-tasks goes through the approval gate — the
# osw-ci library's steps (vars/) — and none carries its own copy. CI
# exercises the gate end to end only through jobs/jenkins-dr-test, so
# this proves every other job uses exactly that code: loads the library,
# runs an Approval stage on approvalGate(), builds on buildLabel() and
# checks assertOwnNode() first — and defines none of those itself (a
# script method of the same name would silently win over the library's).
# Usage: scripts/check_approval_gate.sh   (exit 1 on any problem)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Not gated: no Gerrit trigger, only central's own scheduled maintenance.
EXEMPT="periodic-tasks"
STEPS=(approvalGate buildLabel assertOwnNode buildOwner)

failed=0
for step in "${STEPS[@]}"; do
    [[ -f "${REPO_ROOT}/vars/${step}.groovy" ]] \
        || { echo "✗ vars/${step}.groovy is missing"; failed=1; }
done

for jenkinsfile in "${REPO_ROOT}"/jobs/*/Jenkinsfile; do
    job="$(basename "$(dirname "$jenkinsfile")")"
    [[ "$job" == "$EXEMPT" ]] && continue
    problems=()
    grep -q "^@Library('osw-ci') _$" "$jenkinsfile" \
        || problems+=("doesn't load the library (@Library('osw-ci') _)")
    grep -q "^    agent none$" "$jenkinsfile" \
        || problems+=("pipeline isn't 'agent none' (Approval would hold a node)")
    grep -qE "^ +approvalGate\((allowCentralBuilds: true)?\)$" "$jenkinsfile" \
        || problems+=("no Approval stage calling approvalGate()")
    grep -q "agent { label buildLabel() }" "$jenkinsfile" \
        || problems+=("build stage doesn't run on buildLabel()")
    grep -q "currentBuild.description = assertOwnNode()" "$jenkinsfile" \
        || problems+=("build stage doesn't start with assertOwnNode()")
    for step in "${STEPS[@]}"; do
        grep -qE "^\s*def\s+${step}\s*\(" "$jenkinsfile" \
            && problems+=("defines its own ${step}() — would override the library's")
    done
    if [[ ${#problems[@]} -gt 0 ]]; then
        failed=1
        for p in "${problems[@]}"; do echo "✗ jobs/${job}: ${p}"; done
    else
        echo "✓ jobs/${job}"
    fi
done
exit "$failed"
