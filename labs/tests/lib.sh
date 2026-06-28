#!/bin/bash
###############################################################################
# Test Library — shared functions for all lab tests
###############################################################################

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TEST_NS=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo -e "  ${GREEN}✓${NC} $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo -e "  ${RED}✗${NC} $1"
}

skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  echo -e "  ${YELLOW}⊘${NC} $1 (skipped)"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc (expected: $expected, got: $actual)"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    pass "$desc"
  else
    fail "$desc (expected to contain: $needle)"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    fail "$desc (should not contain: $needle)"
  else
    pass "$desc"
  fi
}

assert_cmd() {
  local desc="$1"
  shift
  if "$@" &>/dev/null; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

assert_cmd_fails() {
  local desc="$1"
  shift
  if "$@" &>/dev/null; then
    fail "$desc (expected failure)"
  else
    pass "$desc"
  fi
}

# Wait for pods matching a label to be Ready (max wait seconds)
wait_for_pods() {
  local ns="$1" label="$2" expected="$3" timeout="${4:-120}"
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local ready
    ready=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | grep -c "Running" || true)
    if [ "$ready" -ge "$expected" ]; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

# Wait for a single named pod to be Ready
wait_for_pod() {
  local ns="$1" name="$2" timeout="${3:-120}"
  kubectl wait --for=condition=Ready "pod/$name" -n "$ns" --timeout="${timeout}s" &>/dev/null
}

# Wait for deployment rollout
wait_for_deploy() {
  local ns="$1" name="$2" timeout="${3:-120}"
  kubectl rollout status "deployment/$name" -n "$ns" --timeout="${timeout}s" &>/dev/null
}

# Clean up a namespace
cleanup_ns() {
  local ns="$1"
  if kubectl get namespace "$ns" &>/dev/null; then
    kubectl delete namespace "$ns" --timeout=60s &>/dev/null || true
  fi
}

# Wait until a local port-forward is actually serving (curl connects), up to
# `timeout` seconds. Fixed sleeps race under parallel load / on small hosts
# (e.g. Cloud9), so poll instead.
wait_for_port() {
  local port="$1" timeout="${2:-20}" i=0
  while [ $i -lt $timeout ]; do
    if curl -s -o /dev/null --max-time 2 "http://localhost:${port}/"; then
      return 0
    fi
    sleep 1; i=$((i+1))
  done
  return 1
}

# Print test summary
summary() {
  local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
  echo ""
  echo "───────────────────────────────────────"
  echo -e "  ${GREEN}Passed:${NC}  $PASS_COUNT"
  echo -e "  ${RED}Failed:${NC}  $FAIL_COUNT"
  echo -e "  ${YELLOW}Skipped:${NC} $SKIP_COUNT"
  echo "  Total:   $total"
  echo "───────────────────────────────────────"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    return 1
  fi
  return 0
}
