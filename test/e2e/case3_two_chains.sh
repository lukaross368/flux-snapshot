#!/usr/bin/env bash
# Test Case 3: Simultaneous Independent Failures — Two Chains
#
#   tc3-frontend-source (GitRepository, repo not found)
#       |
#   tc3-frontend-base  (Kustomization, sourceRef -> tc3-frontend-source)
#       |--- tc3-frontend-ui (Kustomization, dependsOn tc3-frontend-base)
#
#   tc3-backend-source (GitRepository, different repo not found)
#       |
#   tc3-backend-base   (Kustomization, sourceRef -> tc3-backend-source)
#       '--- tc3-backend-api (Kustomization, dependsOn tc3-backend-base)
#
# Validates: two independent root causes generate two separate notification groups,
# dedup key is per-root-cause (suppressing frontend duplicates does NOT suppress
# backend), chains do not bleed into each other.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

[[ "${1:-}" != "--no-setup" ]] && setup_cluster
build_controller


section "fixtures"
info "cleaning up previous run"
delete_objects \
  tc3-frontend-source tc3-frontend-base tc3-frontend-ui \
  tc3-backend-source  tc3-backend-base  tc3-backend-api

info "applying objects"
kubectl apply -f - <<'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: tc3-frontend-source
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/flux-snapshot-test/tc3-frontend-does-not-exist
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc3-frontend-base
  namespace: flux-system
spec:
  interval: 30s
  path: ./base
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc3-frontend-source
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc3-frontend-ui
  namespace: flux-system
spec:
  interval: 30s
  path: ./ui
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc3-frontend-source
  dependsOn:
    - name: tc3-frontend-base
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: tc3-backend-source
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/flux-snapshot-test/tc3-backend-does-not-exist
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc3-backend-base
  namespace: flux-system
spec:
  interval: 30s
  path: ./base
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc3-backend-source
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc3-backend-api
  namespace: flux-system
spec:
  interval: 30s
  path: ./api
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc3-backend-source
  dependsOn:
    - name: tc3-backend-base
EOF

wait_for_failures tc3-frontend-base tc3-frontend-ui tc3-backend-base tc3-backend-api


section "controller"
info "running for 25s to capture initial reconcile burst"
logs=$(run_controller 25)


section "assertions"

# Two independent root causes — exactly 2 notifications fire
assert_msg_count "$logs" "root cause" 2

# Both root causes are identified correctly
assert_root_cause_present "$logs" "tc3-frontend-source" "GitRepository"
assert_root_cause_present "$logs" "tc3-backend-source"  "GitRepository"

# Frontend chain must contain frontend objects and must NOT contain backend objects
frontend_chain=$( echo "$logs" \
  | jq -r 'select(.msg == "affected chain") | .chain' \
  | grep "tc3-frontend" | head -1 )

if [[ -n "$frontend_chain" ]]; then
  pass "frontend chain found"
  if echo "$frontend_chain" | grep -q "tc3-backend"; then
    fail "frontend chain isolation" "no backend objects in frontend chain" "found: $frontend_chain"
  else
    pass "frontend chain contains no backend objects"
  fi
else
  fail "frontend chain found" "a chain containing tc3-frontend" "none found"
fi

# Backend chain must contain backend objects and must NOT contain frontend objects
backend_chain=$( echo "$logs" \
  | jq -r 'select(.msg == "affected chain") | .chain' \
  | grep "tc3-backend" | head -1 )

if [[ -n "$backend_chain" ]]; then
  pass "backend chain found"
  if echo "$backend_chain" | grep -q "tc3-frontend"; then
    fail "backend chain isolation" "no frontend objects in backend chain" "found: $backend_chain"
  else
    pass "backend chain contains no frontend objects"
  fi
else
  fail "backend chain found" "a chain containing tc3-backend" "none found"
fi

# Warning events emitted for both source objects
assert_warning_event "$logs" "tc3-frontend-source"
assert_warning_event "$logs" "tc3-backend-source"


section "cleanup"
delete_objects \
  tc3-frontend-source tc3-frontend-base tc3-frontend-ui \
  tc3-backend-source  tc3-backend-base  tc3-backend-api
info "done"

summary
