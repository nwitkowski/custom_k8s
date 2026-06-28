#!/bin/bash
###############################################################################
# Parallel Lab Test Runner
#
# Each lab test uses its own uniquely-named namespace and (PID-suffixed)
# cluster-scoped resources, so the labs are independent and safe to run
# concurrently. This runner launches them through a bounded job pool and
# aggregates the per-lab pass/fail/skip counts.
#
# Usage:
#   bash run-parallel.sh                 # all labs (platform + 1..13 + scheduling)
#   bash run-parallel.sh 5 6 7           # only these labs
#   bash run-parallel.sh 2s              # the scheduling companion
#   JOBS=4 bash run-parallel.sh          # cap concurrency (default 6)
#
# Portable to bash 3.2 (macOS) — no `wait -n`; uses a `jobs -rp` semaphore.
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOBS="${JOBS:-6}"
RESULTS_DIR="${RESULTS_DIR:-$(mktemp -d -t labtests)}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

# Map a lab token to its test script path.
script_for() {
  case "$1" in
    platform)        echo "$SCRIPT_DIR/test-platform.sh" ;;
    2s|scheduling)   echo "$SCRIPT_DIR/test-lab-02-scheduling.sh" ;;
    *)               printf "%s/test-lab-%02d.sh\n" "$SCRIPT_DIR" "$1" ;;
  esac
}

# Lab list
if [ $# -eq 0 ]; then
  LABS=(platform 1 2 2s 3 4 5 6 7 8 9 10 11 12 13)
else
  LABS=("$@")
fi

echo -e "${BOLD}Parallel Lab Test Suite${NC}"
echo "Started:  $(date)"
echo "Pool:     $JOBS concurrent"
echo "Logs:     $RESULTS_DIR"
echo "Labs:     ${LABS[*]}"

# ─── Launch with a bounded job pool ────────────────────────────────────────
LAUNCHED=()
for lab in "${LABS[@]}"; do
  script="$(script_for "$lab")"
  if [ ! -f "$script" ]; then
    echo -e "${YELLOW}skip $lab — $(basename "$script") not found${NC}"
    continue
  fi
  # Throttle: wait until a slot frees.
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 1; done
  log="$RESULTS_DIR/lab-${lab}.log"
  ( bash "$script" >"$log" 2>&1 ) &
  LAUNCHED+=("$lab")
  echo "  → launched $lab (pid $!)"
done

echo ""
echo "All launched; waiting for completion..."
wait

# ─── Aggregate ─────────────────────────────────────────────────────────────
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0; FAILED_LABS=""
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
printf "${BOLD}%-14s %8s %8s %8s${NC}\n" "Lab" "Passed" "Failed" "Skipped"
echo    "──────────────────────────────────────────────────────"
for lab in "${LAUNCHED[@]}"; do
  log="$RESULTS_DIR/lab-${lab}.log"
  clean=$(sed "s/$(printf '\033')\[[0-9;]*m//g" "$log" 2>/dev/null)
  p=$(echo "$clean" | grep "Passed:"  | grep -oE '[0-9]+' | head -1)
  f=$(echo "$clean" | grep "Failed:"  | grep -oE '[0-9]+' | head -1)
  s=$(echo "$clean" | grep "Skipped:" | grep -oE '[0-9]+' | head -1)
  p=${p:-0}; f=${f:-0}; s=${s:-0}
  TOTAL_PASS=$((TOTAL_PASS + p)); TOTAL_FAIL=$((TOTAL_FAIL + f)); TOTAL_SKIP=$((TOTAL_SKIP + s))
  color="$GREEN"; [ "$f" -gt 0 ] && { color="$RED"; FAILED_LABS="$FAILED_LABS $lab"; }
  printf "${color}%-14s %8s %8s %8s${NC}\n" "$lab" "$p" "$f" "$s"
done
echo "──────────────────────────────────────────────────────"
printf "${BOLD}%-14s %8s %8s %8s${NC}\n" "TOTAL" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"
echo ""
if [ -n "$FAILED_LABS" ]; then
  echo -e "${RED}Failed labs:${NC}$FAILED_LABS"
  echo "Inspect:  grep -nE '✗|FAIL' $RESULTS_DIR/lab-<lab>.log"
fi
echo "Finished: $(date)"
[ -z "$FAILED_LABS" ]
