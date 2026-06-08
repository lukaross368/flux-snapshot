#!/usr/bin/env bash
# Runs all integration test cases against the kind cluster.
# Cluster setup and controller build happen once; each case script receives
# --no-setup to skip redundant bootstrapping.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

setup_cluster
build_controller

# remove stale objects from any previous failed run

section "pre-run cleanup"
info "removing any stale test objects"
for name in \
  tc1-source tc1-infra tc1-app \
  tc2-source tc2-platform tc2-team-a tc2-team-b tc2-team-c \
  tc3-frontend-source tc3-frontend-base tc3-frontend-ui \
  tc3-backend-source tc3-backend-base tc3-backend-api \
  broken-repo broken-kustomization broken-source infra app-a app-b; do
  kubectl delete gitrepository "$name" -n flux-system --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete kustomization  "$name" -n flux-system --ignore-not-found >/dev/null 2>&1 || true
done
info "done"

passed=0; failed=0; results=()

run_case() {
  local label=$1 script=$2
  echo ""
  echo -e "${CYAN}${BOLD}$(printf '=%.0s' {1..60})${NC}"
  echo -e "${CYAN}${BOLD}  $label${NC}"
  echo -e "${CYAN}${BOLD}$(printf '=%.0s' {1..60})${NC}"

  if bash "$script" --no-setup; then
    (( passed++ )) || true
    results+=("${GREEN}✓${NC}  $label")
  else
    (( failed++ )) || true
    results+=("${RED}✗${NC}  $label")
  fi
}

run_case "Case 1: Broken Source — Linear Chain"              "$SCRIPT_DIR/case1_linear.sh"
run_case "Case 2: Shared Infrastructure — Fan-Out"           "$SCRIPT_DIR/case2_fanout.sh"
run_case "Case 3: Simultaneous Independent Failures"         "$SCRIPT_DIR/case3_two_chains.sh"

echo ""
echo -e "${CYAN}${BOLD}$(printf '=%.0s' {1..60})${NC}"
echo -e "${CYAN}${BOLD}  RESULTS${NC}"
echo -e "${CYAN}${BOLD}$(printf '=%.0s' {1..60})${NC}"
for r in "${results[@]}"; do echo -e "  $r"; done
echo ""
if [[ $failed -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}ALL PASSED${NC}  ($passed / $((passed + failed)))"
  exit 0
else
  echo -e "  ${RED}${BOLD}$failed FAILED${NC}  ($passed passed)"
  exit 1
fi
