#!/usr/bin/env bash
# Test Case 1: Broken Source — Linear Chain
#
#   tc1-source (GitRepository, auth failure)
#       |
#   tc1-infra  (Kustomization, sourceRef -> tc1-source)
#       |
#   tc1-app    (Kustomization, dependsOn tc1-infra, sourceRef -> tc1-source)
#
# Validates: root cause correctly identified as GitRepository (not the downstream
# Kustomization), linear dependsOn + sourceRef traversal, dedup collapses two
# reconciles into one notification.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

[[ "${1:-}" != "--no-setup" ]] && setup_cluster
build_controller

section "fixtures"
info "cleaning up previous run"
delete_objects tc1-source tc1-infra tc1-app

info "applying objects"
kubectl apply -f - <<'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: tc1-source
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/flux-snapshot-test/tc1-does-not-exist
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc1-infra
  namespace: flux-system
spec:
  interval: 30s
  path: ./infra
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc1-source
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc1-app
  namespace: flux-system
spec:
  interval: 30s
  path: ./app
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc1-source
  dependsOn:
    - name: tc1-infra
EOF

wait_for_failures tc1-infra tc1-app

section "controller"
info "running for 25s to capture initial reconcile burst"
logs=$(run_controller 25)

section "assertions"

# Exactly one notification fires despite two failing Kustomizations sharing the same root cause
assert_msg_count "$logs" "root cause" 1

# Root cause must be the GitRepository, not a downstream Kustomization
assert_root_cause "$logs" "tc1-source" "GitRepository"

# Chain must trace from the trigger to the root cause.
# tc1-infra and tc1-source are always present; tc1-app only appears when it fires first.
trigger=$( echo "$logs" | jq -rc 'select(.msg == "root cause") | .details.trigger' | head -1 )
if [[ "$trigger" == "tc1-app" ]]; then
  assert_chain_contains "$logs" "tc1-app" "tc1-infra" "tc1-source"
else
  assert_chain_contains "$logs" "tc1-infra" "tc1-source"
fi

# One of the two Kustomizations is deduped — it must not appear as a trigger
# (whichever fires second sees tc1-source already notified within the window)
# We can't predict which fires first, so we assert that NOT BOTH appear as triggers
trigger_count=$( echo "$logs" | jq -c 'select(.msg == "root cause")' \
  | jq -r '.details.trigger' | grep -cE 'tc1-infra|tc1-app' || true )
if [[ "$trigger_count" -eq 1 ]]; then
  pass "exactly one trigger fired (other was deduped)"
else
  fail "dedup" "exactly 1 trigger" "$trigger_count triggers fired"
fi

# Warning event must be attached to the source object
assert_warning_event "$logs" "tc1-source"

section "cleanup"
delete_objects tc1-source tc1-infra tc1-app
info "done"

summary
