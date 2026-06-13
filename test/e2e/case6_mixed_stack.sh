#!/usr/bin/env bash
# Test Case 6: Full Platform Stack — Four-Hop Mixed Chain
#
#   tc6-platform-git (GitRepository, auth failure)
#       |                  \
#   tc6-cert-manager-crds   tc6-cert-manager        tc6-jetstack (HelmRepository, HEALTHY)
#   (Kustomization)         (HelmRelease,                |
#                            chart-from-git)             |
#                               ^                        |
#                               | dependsOn              |
#                            tc6-api-gateway ------------+  (chartRef)
#                            (HelmRelease)
#                               ^
#                               | healthCheck
#                            tc6-ingress-config
#                            (Kustomization, sourceRef -> tc6-apps-git HEALTHY)
#
# Validates: 4-hop mixed-type traversal (KS -> HR -> HR -> GitRepository) using
# both cross-type mechanisms, fan-in dedup of tc6-platform-git, healthy leaves
# (tc6-jetstack, tc6-apps-git) never selected as root cause, 4 failing objects
# -> 1 notification.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

[[ "${1:-}" != "--no-setup" ]] && setup_cluster
build_controller

section "fixtures"
info "cleaning up previous run"
delete_objects tc6-platform-git tc6-apps-git tc6-jetstack \
  tc6-cert-manager-crds tc6-cert-manager tc6-api-gateway tc6-ingress-config

info "applying objects"
kubectl create namespace tc6-apps --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: tc6-platform-git
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/flux-snapshot-test/tc6-does-not-exist
  ref:
    branch: main
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: tc6-apps-git
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/stefanprodan/podinfo
  ref:
    branch: master
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: tc6-jetstack
  namespace: flux-system
spec:
  interval: 30s
  url: https://charts.jetstack.io
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc6-cert-manager-crds
  namespace: flux-system
spec:
  interval: 30s
  path: ./crds
  prune: true
  sourceRef:
    kind: GitRepository
    name: tc6-platform-git
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tc6-cert-manager
  namespace: flux-system
spec:
  interval: 30s
  chart:
    spec:
      chart: ./charts/cert-manager
      sourceRef:
        kind: GitRepository
        name: tc6-platform-git
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tc6-api-gateway
  namespace: flux-system
spec:
  interval: 30s
  dependsOn:
    - name: tc6-cert-manager
  chart:
    spec:
      chart: cert-manager
      sourceRef:
        kind: HelmRepository
        name: tc6-jetstack
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tc6-ingress-config
  namespace: flux-system
spec:
  interval: 30s
  timeout: 30s
  # See tc5-app-config: explicit retryInterval keeps Ready=False observable
  # between health check attempts.
  retryInterval: 2m
  path: ./kustomize
  prune: true
  targetNamespace: tc6-apps
  sourceRef:
    kind: GitRepository
    name: tc6-apps-git
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: tc6-api-gateway
      namespace: flux-system
EOF

wait_for_ready gitrepository/tc6-apps-git helmrepository/tc6-jetstack
wait_for_failures \
  gitrepository/tc6-platform-git \
  tc6-cert-manager-crds \
  helmrelease/tc6-cert-manager \
  helmrelease/tc6-api-gateway \
  tc6-ingress-config

section "controller"
info "running for 25s to capture initial reconcile burst"
logs=$(run_controller 25)

section "assertions"

# Four failing objects share one root cause -> one notification
assert_msg_count "$logs" "root cause" 1

# Root cause is the broken GitRepository at the base — RootCause() must pick the
# Ready=False leaf, not the healthy tc6-jetstack or tc6-apps-git leaves
assert_root_cause "$logs" "tc6-platform-git" "GitRepository"

# Chain traces from whichever trigger fired first down to the root cause
trigger=$( echo "$logs" | jq -rc 'select(.msg == "root cause") | .details.trigger' | head -1 )
# Kind-qualified tokens: "tc6-cert-manager" is a substring of
# "tc6-cert-manager-crds", so bare names would give false positives
case "$trigger" in
  tc6-ingress-config)
    assert_chain_contains "$logs" "tc6-ingress-config(Kustomization)" \
      "tc6-api-gateway(HelmRelease)" "tc6-cert-manager(HelmRelease)" "tc6-platform-git(GitRepository)" ;;
  tc6-api-gateway)
    assert_chain_contains "$logs" "tc6-api-gateway(HelmRelease)" \
      "tc6-cert-manager(HelmRelease)" "tc6-platform-git(GitRepository)" ;;
  tc6-cert-manager)
    assert_chain_contains "$logs" "tc6-cert-manager(HelmRelease)" "tc6-platform-git(GitRepository)" ;;
  *)
    assert_chain_contains "$logs" "tc6-cert-manager-crds(Kustomization)" "tc6-platform-git(GitRepository)" ;;
esac

# The chain is the path to the root cause: healthy side leaves are in the
# snapshot but must not appear in the chain string
assert_chain_excludes "$logs" "tc6-jetstack"
assert_chain_excludes "$logs" "tc6-apps-git"

# Dedup: exactly one of the four failing objects appears as a trigger
trigger_count=$( echo "$logs" | jq -c 'select(.msg == "root cause")' \
  | jq -r '.details.trigger' \
  | grep -cE 'tc6-cert-manager-crds|tc6-cert-manager|tc6-api-gateway|tc6-ingress-config' || true )
if [[ "$trigger_count" -eq 1 ]]; then
  pass "exactly one trigger fired (others were deduped)"
else
  fail "dedup" "exactly 1 trigger" "$trigger_count triggers fired"
fi

# Warning event must be attached to the broken GitRepository
assert_warning_event "$logs" "tc6-platform-git"

section "cleanup"
delete_objects tc6-platform-git tc6-apps-git tc6-jetstack \
  tc6-cert-manager-crds tc6-cert-manager tc6-api-gateway tc6-ingress-config
kubectl delete namespace tc6-apps --ignore-not-found --wait=false >/dev/null 2>&1 || true
info "done"

summary
