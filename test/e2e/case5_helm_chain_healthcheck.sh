#!/usr/bin/env bash
# Test Case 5: HelmRepository Failure Cascades Through Two HelmReleases into a Kustomization
#
#   tc5-company-charts (HelmRepository, no such host)
#       |            \
#   tc5-postgresql    \         tc5-app-git (GitRepository, HEALTHY: podinfo)
#   (HelmRelease)      \            |
#       |               \           |
#   tc5-api-server ------+      tc5-app-config
#   (HelmRelease, dependsOn)    (Kustomization, sourceRef -> tc5-app-git,
#       ^                        healthChecks -> HelmRelease tc5-api-server)
#       |________________________________|
#
# Validates: KS healthChecks -> HelmRelease cross-type edge, HR -> HR dependsOn
# traversal, chart sourceRef -> HelmRepository, root cause is the HelmRepository,
# healthy GitRepository leaf is never selected as root cause.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

[[ "${1:-}" != "--no-setup" ]] && setup_cluster
build_controller

section "fixtures"
info "cleaning up previous run"
delete_objects tc5-company-charts tc5-postgresql tc5-api-server tc5-app-git tc5-app-config

info "applying objects"
kubectl create namespace tc5-apps --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: tc5-company-charts
  namespace: flux-system
spec:
  interval: 30s
  url: https://charts.tc5-company.invalid
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tc5-postgresql
  namespace: flux-system
spec:
  interval: 30s
  chart:
    spec:
      chart: postgresql
      sourceRef:
        kind: HelmRepository
        name: tc5-company-charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tc5-api-server
  namespace: flux-system
spec:
  interval: 30s
  dependsOn:
    - name: tc5-postgresql
  chart:
    spec:
      chart: api-server
      sourceRef:
        kind: HelmRepository
        name: tc5-company-charts
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: tc5-app-git
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/stefanprodan/podinfo
  ref:
    branch: master
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc5-app-config
  namespace: flux-system
spec:
  interval: 30s
  timeout: 30s
  # Without an explicit retryInterval the next reconcile is due the moment a
  # 30s health check times out, so Ready=False is overwritten with Progressing
  # within milliseconds and the failure is never stably observable.
  retryInterval: 2m
  path: ./kustomize
  prune: true
  targetNamespace: tc5-apps
  sourceRef:
    kind: GitRepository
    name: tc5-app-git
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: tc5-api-server
      namespace: flux-system
EOF

wait_for_ready gitrepository/tc5-app-git
wait_for_failures \
  helmrepository/tc5-company-charts \
  helmrelease/tc5-postgresql \
  helmrelease/tc5-api-server \
  tc5-app-config

section "controller"
info "running for 25s to capture initial reconcile burst"
logs=$(run_controller 25)

section "assertions"

# Three failing objects share one root cause -> one notification
assert_msg_count "$logs" "root cause" 1

# Root cause must be the HelmRepository, not any HR or the health-checking KS
assert_root_cause "$logs" "tc5-company-charts" "HelmRepository"

# Chain traces from whichever trigger fired first down to the HelmRepository
trigger=$( echo "$logs" | jq -rc 'select(.msg == "root cause") | .details.trigger' | head -1 )
case "$trigger" in
  tc5-app-config)
    assert_chain_contains "$logs" "tc5-app-config" "tc5-api-server" "tc5-postgresql" "tc5-company-charts" ;;
  tc5-api-server)
    assert_chain_contains "$logs" "tc5-api-server" "tc5-postgresql" "tc5-company-charts" ;;
  *)
    assert_chain_contains "$logs" "tc5-postgresql" "tc5-company-charts" ;;
esac

# The chain is the path to the root cause: the healthy GitRepository is in the
# snapshot but must not appear in the chain string
assert_chain_excludes "$logs" "tc5-app-git"

# Dedup: exactly one of the three failing objects appears as a trigger
trigger_count=$( echo "$logs" | jq -c 'select(.msg == "root cause")' \
  | jq -r '.details.trigger' | grep -cE 'tc5-postgresql|tc5-api-server|tc5-app-config' || true )
if [[ "$trigger_count" -eq 1 ]]; then
  pass "exactly one trigger fired (others were deduped)"
else
  fail "dedup" "exactly 1 trigger" "$trigger_count triggers fired"
fi

# Warning event must be attached to the broken HelmRepository
assert_warning_event "$logs" "tc5-company-charts"

section "cleanup"
delete_objects tc5-company-charts tc5-postgresql tc5-api-server tc5-app-git tc5-app-config
kubectl delete namespace tc5-apps --ignore-not-found --wait=false >/dev/null 2>&1 || true
info "done"

summary
