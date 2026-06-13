#!/usr/bin/env bash
# Shared library for flux-snapshot integration tests.
# Source this file from each test case script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="flux-snapshot-test"
NS="flux-system"
BINARY="$REPO_ROOT/bin/flux-snapshot"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m';  BOLD='\033[1m';   DIM='\033[2m';  NC='\033[0m'

PASS_COUNT=0; FAIL_COUNT=0

section() { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
info()    { echo -e "  ${DIM}·${NC} $*"; }

pass() {
  echo -e "  ${GREEN}✓${NC} $1"
  (( PASS_COUNT++ )) || true
}

fail() {
  local name=$1 expected=$2 actual=$3 raw=${4:-}
  echo -e "  ${RED}✗ FAIL${NC}  ${BOLD}${name}${NC}"
  echo -e "    ${YELLOW}expected:${NC} ${expected}"
  echo -e "    ${RED}actual:  ${NC} ${actual}"
  if [[ -n "$raw" ]]; then
    echo -e "    ${DIM}log:${NC}"
    echo "$raw" | jq -C . 2>/dev/null | sed 's/^/      /' || echo "      $raw"
  fi
  (( FAIL_COUNT++ )) || true
}

summary() {
  echo ""
  if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}PASSED${NC}  ${PASS_COUNT} assertions"
  else
    echo -e "  ${RED}${BOLD}FAILED${NC}  ${FAIL_COUNT} failed / ${PASS_COUNT} passed"
    exit 1
  fi
}

setup_cluster() {
  section "cluster"

  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "cluster already exists"
  else
    info "creating cluster $CLUSTER_NAME"
    kind create cluster --name "$CLUSTER_NAME"
  fi
  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

  if kubectl -n flux-system get deployment/source-controller &>/dev/null; then
    info "Flux already installed"
  else
    info "installing Flux v2.4.0"
    for i in 1 2 3; do
      kubectl apply -f "https://github.com/fluxcd/flux2/releases/download/v2.4.0/install.yaml" && break
      echo "  attempt $i failed, retrying..."; sleep 10
    done
    kubectl -n flux-system wait --for=condition=available --timeout=120s \
      deployment/source-controller deployment/kustomize-controller \
      deployment/notification-controller deployment/helm-controller
  fi
}

delete_objects() {
  for name in "$@"; do
    for kind in gitrepository kustomization helmrelease helmrepository; do
      kubectl delete "$kind" "$name" -n "$NS" --ignore-not-found 2>/dev/null || true
    done
  done
}

# _ready_status <kind/name | name>   (bare names default to kustomization)
_ready_status() {
  local ref=$1 kind name
  if [[ "$ref" == */* ]]; then kind=${ref%%/*}; name=${ref#*/}; else kind=kustomization; name=$ref; fi
  kubectl get "$kind" "$name" -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo ""
}

# wait_for_condition <kind/name | name> <True|False>
wait_for_condition() {
  local ref=$1 want=$2
  local deadline=$(( SECONDS + 120 ))
  while [[ $SECONDS -lt $deadline ]]; do
    [[ "$(_ready_status "$ref")" == "$want" ]] && return 0
    sleep 3
  done
  echo "TIMEOUT: $ref did not reach Ready=$want within 120s" >&2
  return 1
}

wait_for_failure() { wait_for_condition "$1" "False"; }

wait_for_failures() {
  info "waiting for failures: $*"
  for ref in "$@"; do
    wait_for_failure "$ref"
    info "$ref  Ready=False"
  done
}

wait_for_ready() {
  info "waiting for healthy fixtures: $*"
  for ref in "$@"; do
    wait_for_condition "$ref" "True"
    info "$ref  Ready=True"
  done
}

build_controller() {
  section "build"
  info "compiling $BINARY"
  go build -o "$BINARY" "$REPO_ROOT/cmd/manager"
}

run_controller() {
  local timeout_secs=${1:-25}
  pkill -f flux-snapshot 2>/dev/null || true
  sleep 1

  local tmpfile
  tmpfile=$(mktemp)
  "$BINARY" >"$tmpfile" 2>&1 &
  local pid=$!
  sleep "$timeout_secs"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  cat "$tmpfile"
  rm -f "$tmpfile"
}

_filter_msg() { echo "$1" | jq -c --arg m "$2" 'select(.msg == $m)' 2>/dev/null || true; }

# assert_msg_count <logs> <msg> <expected_count>
assert_msg_count() {
  local logs=$1 msg=$2 expected=$3
  local actual
  actual=$( _filter_msg "$logs" "$msg" | wc -l | tr -d ' ' )
  if [[ "$actual" -eq "$expected" ]]; then
    pass "\"$msg\" appears $expected time(s)"
  else
    local sample; sample=$( _filter_msg "$logs" "$msg" | head -1 )
    fail "\"$msg\" count" "count=$expected" "count=$actual" "$sample"
  fi
}

# assert_root_cause <logs> <expected_object> <expected_kind>
assert_root_cause() {
  local logs=$1 exp_obj=$2 exp_kind=$3
  local line; line=$( _filter_msg "$logs" "root cause" | head -1 )
  local act_obj act_kind
  act_obj=$(  echo "$line" | jq -r '.details.object' 2>/dev/null || echo "" )
  act_kind=$( echo "$line" | jq -r '.details.kind'   2>/dev/null || echo "" )
  if [[ "$act_obj" == "$exp_obj" && "$act_kind" == "$exp_kind" ]]; then
    pass "root cause  object=$exp_obj  kind=$exp_kind"
  else
    fail "root cause" \
      "object=$exp_obj  kind=$exp_kind" \
      "object=$act_obj  kind=$act_kind" \
      "$line"
  fi
}

# assert_root_cause_present <logs> <expected_object> <expected_kind>
assert_root_cause_present() {
  local logs=$1 exp_obj=$2 exp_kind=$3
  local found
  found=$( _filter_msg "$logs" "root cause" \
    | jq -c --arg o "$exp_obj" --arg k "$exp_kind" \
        'select(.details.object == $o and .details.kind == $k)' \
    | wc -l | tr -d ' ' )
  if [[ "$found" -gt 0 ]]; then
    pass "root cause present  object=$exp_obj  kind=$exp_kind"
  else
    local sample; sample=$( _filter_msg "$logs" "root cause" | head -1 )
    fail "root cause present" \
      "object=$exp_obj  kind=$exp_kind" \
      "not found in any root cause line" \
      "$sample"
  fi
}

# assert_trigger_suppressed <logs> <name>
assert_trigger_suppressed() {
  local logs=$1 name=$2
  local found
  found=$( _filter_msg "$logs" "root cause" \
    | jq -c --arg n "$name" 'select(.details.trigger == $n)' \
    | wc -l | tr -d ' ' )
  if [[ "$found" -eq 0 ]]; then
    pass "trigger suppressed  $name"
  else
    local line; line=$( _filter_msg "$logs" "root cause" | jq -c --arg n "$name" 'select(.details.trigger == $n)' | head -1 )
    fail "trigger suppressed" "0 root cause lines with trigger=$name" "$found line(s) found" "$line"
  fi
}

# assert_chain_contains <logs> <node>...
assert_chain_contains() {
  local logs=$1; shift
  local chains; chains=$( _filter_msg "$logs" "affected chain" | jq -r '.chain' )
  local failed=0
  for node in "$@"; do
    if echo "$chains" | grep -q "$node"; then
      pass "chain contains  $node"
    else
      fail "chain contains" "chain includes '$node'" "not found in: $chains"
      (( failed++ )) || true
    fi
  done
}

# assert_chain_excludes <logs> <node>
assert_chain_excludes() {
  local logs=$1 node=$2
  local found
  found=$( _filter_msg "$logs" "affected chain" | jq -r '.chain' | grep -c "$node" || true )
  if [[ "$found" -eq 0 ]]; then
    pass "chain excludes  $node"
  else
    local chain; chain=$( _filter_msg "$logs" "affected chain" | jq -r '.chain' | grep "$node" | head -1 )
    fail "chain excludes" "'$node' absent from all chains" "found in: $chain"
  fi
}

# assert_warning_event <logs> <object_name>
assert_warning_event() {
  local logs=$1 exp_obj=$2
  local found
  found=$( echo "$logs" | jq -c --arg o "$exp_obj" \
    'select(.msg == "warning event" and .object == $o)' \
    | wc -l | tr -d ' ' )
  if [[ "$found" -gt 0 ]]; then
    pass "warning event  object=$exp_obj"
  else
    fail "warning event" "warning event for object=$exp_obj" "none found"
  fi
}
