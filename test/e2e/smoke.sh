#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="flux-snapshot-test"

# prerequisites
for cmd in kind kubectl go; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "error: $cmd not found in PATH" >&2
    exit 1
  fi
done

# 1. kind cluster
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "==> cluster $CLUSTER_NAME already exists, skipping create"
else
  echo "==> creating kind cluster: $CLUSTER_NAME"
  kind create cluster --name "$CLUSTER_NAME"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# 2. flux
FLUX_VERSION="v2.4.0"
if kubectl -n flux-system get deployment/source-controller &>/dev/null; then
  echo "==> Flux already installed, skipping"
else
  echo "==> installing Flux ${FLUX_VERSION}"
  for i in 1 2 3; do
    kubectl apply -f "https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/install.yaml" && break
    echo "  attempt $i failed, retrying in 10s..."
    sleep 10
  done
  echo "==> waiting for Flux controllers to be ready"
  kubectl -n flux-system wait --for=condition=available --timeout=120s \
    deployment/source-controller \
    deployment/kustomize-controller \
    deployment/notification-controller \
    deployment/helm-controller
fi

# 3. dependency chain
# Simulates a realistic multi-tier failure:
#
#   broken-source (GitRepository, fails to clone)
#         |
#       infra  (Kustomization, sourceRef -> broken-source)
#       /    \
#   app-a   app-b  (both dependsOn infra)
#
# All four objects will report Ready=False. Our controller should fire for each.
echo "==> applying dependency chain"
kubectl apply -f - <<'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: broken-source
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/flux-snapshot-test/does-not-exist
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra
  namespace: flux-system
spec:
  interval: 30s
  path: ./infra
  prune: true
  sourceRef:
    kind: GitRepository
    name: broken-source
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: app-a
  namespace: flux-system
spec:
  interval: 30s
  path: ./app-a
  prune: true
  sourceRef:
    kind: GitRepository
    name: broken-source
  dependsOn:
    - name: infra
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: app-b
  namespace: flux-system
spec:
  interval: 30s
  path: ./app-b
  prune: true
  sourceRef:
    kind: GitRepository
    name: broken-source
  dependsOn:
    - name: infra
EOF

# 4. wait for failures
echo "==> waiting 45s for chain to report failures..."
sleep 45
echo "==> chain status:"
kubectl get kustomizations -n flux-system

# 5. build controller
echo "==> building controller"
go build -o "$REPO_ROOT/bin/flux-snapshot" "$REPO_ROOT/cmd/manager"

# 6. run controller
# Logs stream to stdout. Look for "root cause" / "affected chain" lines.
echo "==> starting controller (Ctrl+C to stop)"
"$REPO_ROOT/bin/flux-snapshot"
