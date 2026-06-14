#!/bin/bash
###############################################################################
# Platform Setup — Push Infrastructure to Flux Repo & Wait for Reconciliation
#
# Usage:
#   bash setup-platform.sh                          # Push + wait for ready
#   bash setup-platform.sh --skip-wait              # Push only, don't wait
#   GITHUB_TOKEN=xxx bash setup-platform.sh         # Explicit token
#
# Required environment:
#   GITHUB_TOKEN  — GitHub PAT with repo scope (or set in ~/.bashrc)
#
# Optional environment:
#   GITHUB_OWNER  — GitHub org/user (default: auto-detect from Flux GitRepository)
#   FLUX_REPO     — Flux repo name (default: auto-detect from Flux GitRepository)
#   CLUSTER_NAME  — EKS cluster name (default: auto-detect from kubectl)
#   FLUX_DIR      — Path to flux/ definitions (default: auto-detect)
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "  ${GREEN}*${NC} $1"; }
warn()  { echo -e "  ${YELLOW}!${NC} $1"; }
error() { echo -e "  ${RED}✗${NC} $1"; }
die()   { error "$1"; exit 1; }

SKIP_WAIT=false
for arg in "$@"; do
  case "$arg" in
    --skip-wait) SKIP_WAIT=true ;;
  esac
done

echo -e "${BOLD}=== Platform Setup ===${NC}"
echo ""

# ─── Auto-detect settings ──────────────────────────────────────────────────

echo "Detecting configuration..."

# Flux repo URL from the GitRepository resource
FLUX_GIT_URL=$(kubectl get gitrepository flux-system -n flux-system \
  -o jsonpath='{.spec.url}' 2>/dev/null || true)

if [ -z "$FLUX_GIT_URL" ]; then
  die "Cannot detect Flux GitRepository — is Flux bootstrapped?"
fi

# Extract owner/repo from ssh://git@github.com/owner/repo.git
if [[ "$FLUX_GIT_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
  AUTO_OWNER="${BASH_REMATCH[1]}"
  AUTO_REPO="${BASH_REMATCH[2]}"
fi

GITHUB_OWNER="${GITHUB_OWNER:-${AUTO_OWNER:-}}"
FLUX_REPO="${FLUX_REPO:-${AUTO_REPO:-}}"

[ -z "$GITHUB_OWNER" ] && die "Cannot detect GITHUB_OWNER — set it manually"
[ -z "$FLUX_REPO" ]    && die "Cannot detect FLUX_REPO — set it manually"

# GitHub token
if [ -z "${GITHUB_TOKEN:-}" ]; then
  die "GITHUB_TOKEN not set. Export it: export GITHUB_TOKEN=ghp_xxx"
fi

# Cluster name from kubectl context
CLUSTER_NAME="${CLUSTER_NAME:-$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | sed 's|.*/||' || echo "")}"
[ -z "$CLUSTER_NAME" ] && die "Cannot detect CLUSTER_NAME — set it manually"

# Path to flux/ definitions — search common locations
if [ -z "${FLUX_DIR:-}" ]; then
  for candidate in \
    "$SCRIPT_DIR/../../eks-platform/flux" \
    "$HOME/environment/eks-platform/flux" \
    "$HOME/environment/custom_k8s/eks-platform/flux" \
    "$HOME/eks-platform/flux" \
    "/home/ec2-user/environment/eks-platform/flux" \
    "/home/ec2-user/environment/custom_k8s/eks-platform/flux"; do
    if [ -d "$candidate/infrastructure" ]; then
      FLUX_DIR="$(cd "$candidate" && pwd)"
      break
    fi
  done
fi

[ -z "${FLUX_DIR:-}" ] && die "Cannot find flux/ directory — set FLUX_DIR manually"

info "GitHub owner:  $GITHUB_OWNER"
info "Flux repo:     $FLUX_REPO"
info "Cluster name:  $CLUSTER_NAME"
info "Flux dir:      $FLUX_DIR"

# ─── Always push infrastructure to Flux repo ─────────────────────────────

echo ""
echo "Syncing infrastructure definitions to Flux repo..."

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_OWNER}/${FLUX_REPO}.git" \
  "$TMPDIR/repo" 2>/dev/null || die "Failed to clone ${GITHUB_OWNER}/${FLUX_REPO}"

# Copy flux directory
rm -rf "$TMPDIR/repo/flux"
cp -r "$FLUX_DIR" "$TMPDIR/repo/flux"
info "Copied flux/ directory"

# Create cluster infrastructure reference
CLUSTER_DIR="$TMPDIR/repo/clusters/$CLUSTER_NAME"
mkdir -p "$CLUSTER_DIR"
cp "$FLUX_DIR/infrastructure/kustomizations.yaml" "$CLUSTER_DIR/infrastructure.yaml"
info "Created clusters/$CLUSTER_NAME/infrastructure.yaml"

# Ensure the cluster kustomization.yaml includes infrastructure.yaml
CLUSTER_KS="$CLUSTER_DIR/kustomization.yaml"
if [ -f "$CLUSTER_KS" ]; then
  if ! grep -q "infrastructure.yaml" "$CLUSTER_KS"; then
    # Add to resources list
    sed -i.bak '/resources:/a\  - infrastructure.yaml' "$CLUSTER_KS" 2>/dev/null || \
      echo "  - infrastructure.yaml" >> "$CLUSTER_KS"
    rm -f "${CLUSTER_KS}.bak"
    info "Updated cluster kustomization.yaml"
  else
    info "Cluster kustomization.yaml already references infrastructure.yaml"
  fi
else
  cat > "$CLUSTER_KS" <<'KUSTOMIZE'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - flux-system
  - infrastructure.yaml
KUSTOMIZE
  info "Created cluster kustomization.yaml"
fi

cd "$TMPDIR/repo"
git config user.email "terraform@platform-lab"
git config user.name "Terraform"
git add -A

if git diff --cached --quiet; then
  info "No changes needed — Flux repo already up to date"
else
  git commit -m "Sync platform infrastructure definitions" >/dev/null
  git push >/dev/null 2>&1
  info "Pushed changes to ${GITHUB_OWNER}/${FLUX_REPO}"
fi

# ─── Trigger Flux reconciliation ──────────────────────────────────────────

echo ""
echo "Triggering Flux reconciliation..."

flux reconcile source git flux-system 2>/dev/null || warn "flux reconcile source failed (may need a moment)"
sleep 5
flux reconcile kustomization flux-system 2>/dev/null || warn "flux reconcile kustomization failed"

if [ "$SKIP_WAIT" = true ]; then
  echo ""
  echo -e "${YELLOW}Skipping wait. Run 'flux get kustomizations -A' to check progress.${NC}"
  exit 0
fi

# ─── Wait for Kustomizations ─────────────────────────────────────────────

echo ""
echo "Waiting for Flux Kustomizations to reconcile..."

MAX_WAIT=600
ELAPSED=0
EXPECTED_KS=10  # sources, core, security, security-stores, monitoring, networking, logging, gitops, platform, policies

while [ $ELAPSED -lt $MAX_WAIT ]; do
  KS_READY=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers 2>/dev/null | grep -c "True" || true)
  KS_TOTAL=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [ "$KS_TOTAL" -ge "$EXPECTED_KS" ] && [ "$KS_READY" -ge "$EXPECTED_KS" ]; then
    info "All $KS_READY Kustomizations reconciled"
    break
  fi

  printf "\r  Kustomizations: %s/%s ready (waited %ds/%ds)  " "$KS_READY" "$KS_TOTAL" "$ELAPSED" "$MAX_WAIT"
  sleep 15
  ELAPSED=$((ELAPSED + 15))

  # Re-trigger reconciliation periodically
  if [ $((ELAPSED % 60)) -eq 0 ]; then
    flux reconcile source git flux-system &>/dev/null || true
    flux reconcile kustomization flux-system &>/dev/null || true
  fi
done
echo ""

if [ $ELAPSED -ge $MAX_WAIT ]; then
  warn "Timed out waiting for Kustomizations"
  echo "  Not ready:"
  kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers 2>/dev/null | grep -v "True" | awk '{printf "    %s/%s\n", $1, $2}'
fi

# ─── Wait for HelmReleases ───────────────────────────────────────────────

echo ""
echo "Waiting for HelmReleases to deploy..."

ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
  HR_TOTAL=$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  HR_READY=$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | grep -c "True" || true)

  if [ "$HR_TOTAL" -gt 0 ] && [ "$HR_READY" -eq "$HR_TOTAL" ]; then
    info "All $HR_READY HelmReleases ready"
    break
  fi

  printf "\r  HelmReleases: %s/%s ready (waited %ds/%ds)  " "$HR_READY" "$HR_TOTAL" "$ELAPSED" "$MAX_WAIT"
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done
echo ""

if [ $ELAPSED -ge $MAX_WAIT ]; then
  warn "Timed out waiting for HelmReleases"
  echo "  Not ready:"
  kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | grep -v "True" | awk '{printf "    %s/%s — %s\n", $1, $2, $5}'
fi

# ─── Final status ─────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Platform Status:${NC}"
echo ""
echo "Flux Kustomizations:"
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A 2>/dev/null || true
echo ""
echo "Flux HelmReleases:"
kubectl get helmreleases.helm.toolkit.fluxcd.io -A 2>/dev/null || true
echo ""

HR_TOTAL=$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
HR_READY=$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | grep -c "True" || true)

if [ "$HR_TOTAL" -gt 0 ] && [ "$HR_READY" -eq "$HR_TOTAL" ]; then
  echo -e "${GREEN}Platform is ready. All $HR_READY HelmReleases deployed.${NC}"
  exit 0
else
  echo -e "${YELLOW}Platform partially ready: $HR_READY/$HR_TOTAL HelmReleases.${NC}"
  echo "Re-run this script or wait for Flux to finish reconciling."
  exit 1
fi
