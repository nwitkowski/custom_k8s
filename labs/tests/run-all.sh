#!/bin/bash
###############################################################################
# Lab Test Suite Runner
#
# Usage:
#   bash run-all.sh              # Setup platform + run all tests
#   bash run-all.sh platform     # Platform prerequisites only
#   bash run-all.sh 1 3 5        # Run specific labs (no setup)
#   bash run-all.sh 2s           # Run the Lab 2 scheduling companion (alias: scheduling)
#   bash run-all.sh 1-6          # Run a range
#   bash run-all.sh --no-setup   # Skip platform setup, run all tests
#   bash run-all.sh setup        # Run setup only (no tests)
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_LABS=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

run_test_capture() {
  local name="$1" script="$2"
  echo ""
  echo -e "${BOLD}════════════════════════════════════════${NC}"

  local output
  output=$(bash "$script" 2>&1)
  local exit_code=$?
  echo "$output"

  # Extract counts from summary. Strip ANSI color codes first — they contain
  # digits (e.g. yellow = \033[1;33m), which otherwise get parsed as counts.
  local clean p f s
  clean=$(printf '%s\n' "$output" | sed "s/$(printf '\033')\[[0-9;]*m//g")
  p=$(echo "$clean" | grep "Passed:"  | grep -oE '[0-9]+' | head -1)
  f=$(echo "$clean" | grep "Failed:"  | grep -oE '[0-9]+' | head -1)
  s=$(echo "$clean" | grep "Skipped:" | grep -oE '[0-9]+' | head -1)

  TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
  TOTAL_FAIL=$((TOTAL_FAIL + ${f:-0}))
  TOTAL_SKIP=$((TOTAL_SKIP + ${s:-0}))

  if [ "${f:-0}" -gt 0 ]; then
    FAILED_LABS="$FAILED_LABS $name"
  fi
}

# ─── Parse arguments ──────────────────────────────────────────────────────

LABS_TO_RUN=()
RUN_SETUP=false
SETUP_ONLY=false

if [ $# -eq 0 ]; then
  # Default: setup + all tests
  RUN_SETUP=true
  LABS_TO_RUN=("platform" 1 2 2s $(seq 3 13))
elif [ "$1" = "setup" ]; then
  SETUP_ONLY=true
elif [ "$1" = "--no-setup" ]; then
  shift
  if [ $# -eq 0 ]; then
    LABS_TO_RUN=("platform" 1 2 2s $(seq 3 13))
  else
    for arg in "$@"; do
      if [[ "$arg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        for i in $(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"); do
          LABS_TO_RUN+=("$i")
        done
      else
        LABS_TO_RUN+=("$arg")
      fi
    done
  fi
elif [ "$1" = "platform" ]; then
  RUN_SETUP=true
  LABS_TO_RUN=("platform")
else
  for arg in "$@"; do
    if [[ "$arg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      for i in $(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"); do
        LABS_TO_RUN+=("$i")
      done
    else
      LABS_TO_RUN+=("$arg")
    fi
  done
fi

echo -e "${BOLD}Lab Test Suite${NC}"
echo "Started: $(date)"

# ─── Platform Setup ───────────────────────────────────────────────────────

if [ "$RUN_SETUP" = true ] || [ "$SETUP_ONLY" = true ]; then
  echo ""
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Platform Setup${NC}"
  echo -e "${BOLD}════════════════════════════════════════${NC}"

  if [ -f "$SCRIPT_DIR/setup-platform.sh" ]; then
    bash "$SCRIPT_DIR/setup-platform.sh"
    SETUP_EXIT=$?
    if [ $SETUP_EXIT -ne 0 ]; then
      echo -e "${RED}Platform setup did not complete fully. Some tests may fail.${NC}"
    fi
  else
    echo -e "${YELLOW}setup-platform.sh not found — skipping setup${NC}"
  fi

  if [ "$SETUP_ONLY" = true ]; then
    echo ""
    echo "Finished: $(date)"
    exit ${SETUP_EXIT:-0}
  fi
fi

# ─── Run Tests ────────────────────────────────────────────────────────────

echo ""
echo "Running: ${LABS_TO_RUN[*]}"

# Save and restore context
ORIG_NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)

for lab in "${LABS_TO_RUN[@]}"; do
  if [ "$lab" = "platform" ]; then
    run_test_capture "platform" "$SCRIPT_DIR/test-platform.sh"
  elif [ "$lab" = "2s" ] || [ "$lab" = "scheduling" ]; then
    script="$SCRIPT_DIR/test-lab-02-scheduling.sh"
    if [ -f "$script" ]; then
      run_test_capture "lab-02-scheduling" "$script"
    else
      echo -e "${YELLOW}Skipping lab 02-scheduling — test not found${NC}"
    fi
  else
    padded=$(printf "%02d" "$lab")
    script="$SCRIPT_DIR/test-lab-${padded}.sh"
    if [ -f "$script" ]; then
      run_test_capture "lab-${padded}" "$script"
    else
      echo -e "${YELLOW}Skipping lab $padded — test not found${NC}"
    fi
  fi
done

# Restore namespace context
kubectl config set-context --current --namespace="${ORIG_NS:-default}" &>/dev/null

# ─── Final Summary ────────────────────────────────────────────────────────

TOTAL=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))
echo ""
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${BOLD}           FINAL RESULTS                  ${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Passed:${NC}  $TOTAL_PASS"
echo -e "  ${RED}Failed:${NC}  $TOTAL_FAIL"
echo -e "  ${YELLOW}Skipped:${NC} $TOTAL_SKIP"
echo "  Total:   $TOTAL"
echo ""

if [ -n "$FAILED_LABS" ]; then
  echo -e "  ${RED}Failed:${NC}$FAILED_LABS"
fi

echo ""
echo "Finished: $(date)"

if [ "$TOTAL_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
