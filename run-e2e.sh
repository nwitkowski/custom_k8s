#!/usr/bin/env bash
###############################################################################
# End-to-end lab validation
#
# Builds the EKS cluster + GitOps platform with Terraform, runs all 13 lab
# test scripts against the live cluster, then optionally tears it down.
#
# RUN FROM YOUR LOCAL MACHINE as an IAM user (NOT root) with AdministratorAccess.
# Root fails: the EKS access entry binds to the caller ARN, and EKS access
# entries do not accept the account-root principal.
#
# Usage:
#   export TF_VAR_github_token=ghp_xxx     # classic PAT, scopes: repo + delete_repo
#   export GITHUB_TOKEN=$TF_VAR_github_token
#   bash run-e2e.sh [options]
#
# Options:
#   --teardown on-success   (default) destroy only if every test passes; keep on failure
#   --teardown always       destroy regardless of test outcome
#   --teardown never        leave the cluster running (you run terraform destroy yourself)
#   --skip-build            assume the cluster already exists; only refresh kubeconfig + test
#   --skip-tests            build (and optionally tear down) without running the lab tests
#   -h | --help
#
# Survive disconnect: run under tmux/screen, e.g.  tmux new -s e2e 'bash run-e2e.sh'
# (and `caffeinate -s` on macOS so the Mac does not sleep mid-run).
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/eks-platform/terraform"
TESTS_DIR="$SCRIPT_DIR/labs/tests"
LOG_DIR="$SCRIPT_DIR/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/e2e-$STAMP.log"

TEARDOWN="on-success"
DO_BUILD=true
DO_TESTS=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
say()  { echo -e "${BOLD}==>${NC} $*"; }
warn() { echo -e "${YELLOW}!  $*${NC}"; }
die()  { echo -e "${RED}✗  $*${NC}"; exit 1; }

# ─── Parse arguments ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --teardown) TEARDOWN="${2:-}"; shift 2 ;;
    --skip-build) DO_BUILD=false; shift ;;
    --skip-tests) DO_TESTS=false; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done
case "$TEARDOWN" in on-success|always|never) ;; *) die "--teardown must be on-success|always|never" ;; esac

mkdir -p "$LOG_DIR"
# Mirror everything to the log file from here on.
exec > >(tee -a "$LOG") 2>&1

echo -e "${BOLD}=== Lab end-to-end run — $STAMP ===${NC}"
echo "Log: $LOG"
echo "Teardown policy: $TEARDOWN | build=$DO_BUILD | tests=$DO_TESTS"

# ─── Preflight ──────────────────────────────────────────────────────────────
say "Preflight checks"

for t in terraform kubectl helm flux aws jq envsubst; do
  command -v "$t" >/dev/null 2>&1 || die "Required tool not found: $t"
done

CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)" \
  || die "AWS credentials not configured (aws sts get-caller-identity failed)"
echo "    Caller: $CALLER_ARN"
case "$CALLER_ARN" in
  *":root") die "You are authenticated as ACCOUNT ROOT. Use an IAM user with AdministratorAccess — root cannot be an EKS access-entry principal." ;;
esac

# GitHub token: Terraform reads TF_VAR_github_token; setup-platform.sh reads GITHUB_TOKEN.
if [ -z "${TF_VAR_github_token:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then export TF_VAR_github_token="$GITHUB_TOKEN"; fi
if [ -z "${GITHUB_TOKEN:-}" ] && [ -n "${TF_VAR_github_token:-}" ]; then export GITHUB_TOKEN="$TF_VAR_github_token"; fi
[ -n "${TF_VAR_github_token:-}" ] || die "Set TF_VAR_github_token (and GITHUB_TOKEN) to a classic PAT with 'repo' + 'delete_repo' scopes."

[ -f "$TF_DIR/terraform.tfvars" ] || die "Missing $TF_DIR/terraform.tfvars — copy terraform.tfvars.example and edit it."

warn "This provisions a real EKS cluster (default 6 × m5.2xlarge + NAT + EKS control plane ≈ \$2.5-3/hr). It will be billed until torn down."

# ─── Build ──────────────────────────────────────────────────────────────────
if [ "$DO_BUILD" = true ]; then
  say "Building cluster + platform (terraform apply)"
  cd "$TF_DIR"
  terraform init -input=false   || die "terraform init failed"
  terraform apply -auto-approve -input=false || die "terraform apply failed — cluster may be partially created; check $LOG and run terraform destroy if needed."
  cd "$SCRIPT_DIR"
else
  say "Skipping build (--skip-build)"
fi

# ─── Connect kubectl ────────────────────────────────────────────────────────
say "Configuring kubectl"
cd "$TF_DIR"
KCMD="$(terraform output -raw kubeconfig_command 2>/dev/null)" || die "Could not read kubeconfig_command output — does the cluster exist?"
cd "$SCRIPT_DIR"
eval "$KCMD" || die "aws eks update-kubeconfig failed"
kubectl get nodes || die "kubectl cannot reach the cluster"

# ─── Tests ──────────────────────────────────────────────────────────────────
TEST_RC=0
if [ "$DO_TESTS" = true ]; then
  say "Running platform setup + all lab tests (labs/tests/run-all.sh)"
  # run-all.sh runs setup-platform.sh (pushes Flux infra + waits to reconcile) then every test-lab-*.sh
  bash "$TESTS_DIR/run-all.sh"
  TEST_RC=$?
  if [ "$TEST_RC" -eq 0 ]; then say "${GREEN}All tests passed${NC}"; else warn "Tests reported failures (exit $TEST_RC)"; fi
else
  say "Skipping tests (--skip-tests)"
fi

# ─── Teardown ───────────────────────────────────────────────────────────────
do_destroy() {
  say "Tearing down (terraform destroy)"
  cd "$TF_DIR"
  terraform destroy -auto-approve -input=false \
    && say "${GREEN}Cluster destroyed${NC}" \
    || warn "terraform destroy failed — run it manually in $TF_DIR to stop billing."
  cd "$SCRIPT_DIR"
}

case "$TEARDOWN" in
  always)     do_destroy ;;
  never)      warn "Leaving cluster running (--teardown never). Run 'terraform destroy' in $TF_DIR when done." ;;
  on-success) if [ "$TEST_RC" -eq 0 ] && [ "$DO_TESTS" = true ]; then do_destroy
              else warn "Keeping cluster up for debugging (tests failed or were skipped). Destroy manually in $TF_DIR." ; fi ;;
esac

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=== Done — $(date) ===${NC}"
echo "Log saved to: $LOG"
[ "$DO_TESTS" = true ] && echo "Test result: $([ "$TEST_RC" -eq 0 ] && echo PASS || echo "FAIL ($TEST_RC)")"
exit "$TEST_RC"
