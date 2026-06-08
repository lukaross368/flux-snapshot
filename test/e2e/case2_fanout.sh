#!/usr/bin/env bash
# Test Case 2: Shared Infrastructure Breakdown — Fan-Out
#
#   tc2-source (GitRepository, branch not found)
#       |
#   tc2-platform  (Kustomization, sourceRef -> tc2-source)
#       |--- tc2-team-a (Kustomization, dependsOn tc2-platform)
#       |--- tc2-team-b (Kustomization, dependsOn tc2-platform)
#       '--- tc2-team-c (Kustomization, dependsOn tc2-platform)
#
# Validates: dedup collapses 4 reconciles into 1 notification, visited map
# prevents tc2-source appearing multiple times as a node, blast radius chain
# correctly shows the propagation path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

[[ "${1:-}" != "--no-setup" ]] && setup_cluster
build_controller


section "fixtures"
info "cleaning up previous run"
delete_objects tc2-source tc2-platform tc2-team-a tc2-team-b tc2-team-c

info "applying objects"
kubectl apply -f - <<'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: tc2-source
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/flux-snapshot-test/tc2-does-not-exist
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc2-platform
  namespace: flux-system
spec:
  interval: 30s
  path: ./platform
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc2-source
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc2-team-a
  namespace: flux-system
spec:
  interval: 30s
  path: ./team-a
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc2-source
  dependsOn:
    - name: tc2-platform
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc2-team-b
  namespace: flux-system
spec:
  interval: 30s
  path: ./team-b
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc2-source
  dependsOn:
    - name: tc2-platform
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc2-team-c
  namespace: flux-system
spec:
  interval: 30s
  path: ./team-c
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc2-source
  dependsOn:
    - name: tc2-platform
EOF

wait_for_failures tc2-platform tc2-team-a tc2-team-b tc2-team-c


section "controller"
info "running for 25s to capture initial reconcile burst"
logs=$(run_controller 25)


section "assertions"

# 4 Kustomizations all share the same root cause — exactly 1 notification fires
assert_msg_count "$logs" "root cause" 1

# Root cause must be the GitRepository at the base of the chain
assert_root_cause "$logs" "tc2-source" "GitRepository"

# Chain must include tc2-source; the path from trigger to source
assert_chain_contains "$logs" "tc2-source"

# tc2-source should appear in exactly one affected chain line (visited map working)
source_node_count=$( echo "$logs" | jq -r 'select(.msg == "affected chain") | .nodes[]?.name' \
  | grep -c "tc2-source" || true )
if [[ "$source_node_count" -eq 1 ]]; then
  pass "tc2-source node deduped (appears once in chain)"
else
  fail "node dedup" "tc2-source appears 1 time in nodes" "appears $source_node_count times"
fi

# Warning event emitted for the source object
assert_warning_event "$logs" "tc2-source"


section "cleanup"
delete_objects tc2-source tc2-platform tc2-team-a tc2-team-b tc2-team-c
info "done"

summary
