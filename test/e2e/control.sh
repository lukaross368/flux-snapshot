#!/usr/bin/env bash
# Control script: shows what a human has to do manually to debug a Flux failure.
# Run this against the same kind cluster as smoke.sh, then compare the output
# to what flux-snapshot produces in a single log line.
set -euo pipefail

CLUSTER_NAME="flux-snapshot-test"
NS="flux-system"

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

sep() { printf '\n-- %s %s\n' "$1" "$(printf '%0.s-' {1..60})"; }

sep "1. KUSTOMIZATION STATUS"
kubectl get kustomizations -n "$NS" -o wide

sep "2. APP-A CONDITIONS (the trigger)"
kubectl get kustomization app-a -n "$NS" -o jsonpath='{range .status.conditions[*]}type={.type} status={.status} reason={.reason}{"\n"}  {.message}{"\n"}{end}'

sep "3. APP-A EVENTS"
kubectl get events -n "$NS" --field-selector involvedObject.name=app-a --sort-by='.lastTimestamp' 2>/dev/null || echo "(no events)"

sep "4. INFRA CONDITIONS (app-a depends on this)"
kubectl get kustomization infra -n "$NS" -o jsonpath='{range .status.conditions[*]}type={.type} status={.status} reason={.reason}{"\n"}  {.message}{"\n"}{end}'

sep "5. INFRA EVENTS"
kubectl get events -n "$NS" --field-selector involvedObject.name=infra --sort-by='.lastTimestamp' 2>/dev/null || echo "(no events)"

sep "6. GITREPOSITORY STATUS (the actual source)"
kubectl get gitrepositories -n "$NS" -o wide

sep "7. BROKEN-SOURCE CONDITIONS"
kubectl get gitrepository broken-source -n "$NS" -o jsonpath='{range .status.conditions[*]}type={.type} status={.status} reason={.reason}{"\n"}  {.message}{"\n"}{end}'

sep "8. BROKEN-SOURCE EVENTS"
kubectl get events -n "$NS" --field-selector involvedObject.name=broken-source --sort-by='.lastTimestamp' 2>/dev/null || echo "(no events)"

sep "SUMMARY"
echo "To diagnose this failure you had to:"
echo "  1. Notice app-a was failing"
echo "  2. Check its conditions to find it depends on infra"
echo "  3. Check infra — also failing, same message"
echo "  4. Know to look at the sourceRef (not shown in conditions)"
echo "  5. Find and check the GitRepository separately"
echo "  6. Piece together which error is the root cause vs a cascade"
echo ""
echo "flux-snapshot does this in one log line."
