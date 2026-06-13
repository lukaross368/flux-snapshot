#!/usr/bin/env bash
# Test Case 4: Chart-from-Git HelmRelease Blocked by a Broken Git Source
#
#   tc4-platform-git (GitRepository, auth failure)
#       |
#   tc4-prometheus (HelmRelease, chart vendored in the repo:
#                   chart.spec.sourceRef -> tc4-platform-git)
#
# Deliberately the minimal forcing case for HelmRelease support: no
# Kustomization exists in the fixture, so a notification can only be produced
# if the controller watches HelmReleases as triggers and follows the
# chart.spec.sourceRef edge to the GitRepository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

[[ "${1:-}" != "--no-setup" ]] && setup_cluster
build_controller

section "fixtures"
info "cleaning up previous run"
delete_objects tc4-platform-git tc4-prometheus

info "applying objects"
kubectl apply -f - <<'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: tc4-platform-git
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/flux-snapshot-test/tc4-does-not-exist
  ref:
    branch: main
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tc4-prometheus
  namespace: flux-system
spec:
  interval: 30s
  chart:
    spec:
      chart: ./charts/prometheus
      sourceRef:
        kind: GitRepository
        name: tc4-platform-git
EOF

wait_for_failures \
  gitrepository/tc4-platform-git \
  helmrelease/tc4-prometheus

section "controller"
info "running for 25s to capture initial reconcile burst"
logs=$(run_controller 25)

section "assertions"

# The HelmRelease is the only possible trigger -> exactly one notification
assert_msg_count "$logs" "root cause" 1

# Root cause must be the GitRepository, not the HelmRelease
assert_root_cause "$logs" "tc4-platform-git" "GitRepository"

# The trigger must be the HelmRelease
trigger=$( echo "$logs" | jq -rc 'select(.msg == "root cause") | .details.trigger' | head -1 )
if [[ "$trigger" == "tc4-prometheus" ]]; then
  pass "trigger is the HelmRelease  tc4-prometheus"
else
  fail "HR trigger" "trigger=tc4-prometheus" "trigger=${trigger:-<none>}"
fi

# Chain traces from the HR through the chart source edge to the GitRepository
assert_chain_contains "$logs" "tc4-prometheus(HelmRelease)" "tc4-platform-git(GitRepository)"

# Warning event must be attached to the source object
assert_warning_event "$logs" "tc4-platform-git"

section "cleanup"
delete_objects tc4-platform-git tc4-prometheus
info "done"

summary
