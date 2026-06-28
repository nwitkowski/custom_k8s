#!/bin/bash
###############################################################################
# Cloud9 Lab Environment Setup
# Installs all tools and connects to the EKS cluster.
# Run this once after creating your Cloud9 environment and attaching the
# k8s-lab-role IAM role.
#
# Usage:  bash setup-cloud9.sh <usernumber> <cluster-region>
# Example: bash setup-cloud9.sh user01 eu-west-3
# The cluster region is the Cluster region from Lab 1 Parameters (where the EKS
# cluster runs) — NOT the Cloud9 region. They differ in a cross-region setup.
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLUSTER_NAME="${CLUSTER_NAME:-platform-lab}"
# Cluster region: 2nd CLI arg, else the CLUSTER_REGION env var.
# Deliberately NOT AWS_REGION / AWS_DEFAULT_REGION — on a Cloud9 instance those
# resolve to the *Cloud9* region (e.g. eu-central-1), which in this cross-region
# setup is NOT where the cluster lives (e.g. eu-west-3). Using them would connect
# kubeconfig to the wrong region. Require the cluster region explicitly instead;
# validated below.
REGION="${2:-${CLUSTER_REGION:-}}"

# ─── Validate input ────────────────────────────────────────────────────────

if [ -z "${1:-}" ]; then
  echo -e "${RED}Usage: bash setup-cloud9.sh <usernumber> <cluster-region>${NC}"
  echo "Example: bash setup-cloud9.sh user01 eu-west-3"
  exit 1
fi

STUDENT_NAME="$1"

# Cluster region must be resolvable (CLI arg or env) — no silent fallback.
if [ -z "$REGION" ]; then
  echo -e "${RED}ERROR: cluster region not specified.${NC}"
  echo "Pass it as the 2nd argument (the Cluster region from Lab 1 Parameters),"
  echo "or export CLUSTER_REGION first. Example: bash setup-cloud9.sh $STUDENT_NAME eu-west-3"
  exit 1
fi

# Must be valid in namespace names, service accounts, and app names (RFC 1123)
if ! echo "$STUDENT_NAME" | grep -Eq '^[a-z][a-z0-9-]{0,19}$'; then
  echo -e "${RED}ERROR: Invalid student name: $STUDENT_NAME${NC}"
  echo "Use lowercase letters, digits, and hyphens only (start with a letter,"
  echo "20 characters max). No dots, underscores, or uppercase."
  echo "Examples: user01, user02"
  exit 1
fi

echo "Setting up environment for student: $STUDENT_NAME"

# ─── Verify IAM role ───────────────────────────────────────────────────────

echo ""
echo "==> Verifying IAM role..."
CALLER=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)
if echo "$CALLER" | grep -q "k8s-lab-role"; then
  echo -e "${GREEN}IAM role verified: $CALLER${NC}"
else
  echo -e "${RED}ERROR: Expected k8s-lab-role but got: $CALLER${NC}"
  echo "Make sure you have:"
  echo "  1. Disabled Cloud9 managed credentials (Cloud9 > Preferences > AWS Settings)"
  echo "  2. Attached k8s-lab-role to your Cloud9 EC2 instance"
  exit 1
fi

# ─── Resize the root EBS volume (Cloud9 default 10 GB → 100 GB) ─────────────

echo ""
echo "==> Checking root EBS volume size..."
TARGET_GB=100
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 120")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)
EC2_REGION="${AZ%?}"   # strip the trailing AZ letter to get the region

VOLUME_ID=$(aws ec2 describe-volumes --region "$EC2_REGION" \
  --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
  --query "Volumes[0].VolumeId" --output text)
CURRENT_GB=$(aws ec2 describe-volumes --region "$EC2_REGION" \
  --volume-ids "$VOLUME_ID" --query "Volumes[0].Size" --output text)

REBOOT_NEEDED=false
if [ "$CURRENT_GB" -ge "$TARGET_GB" ]; then
  echo -e "${GREEN}Root volume already ${CURRENT_GB} GB — no resize needed${NC}"
else
  echo "==> Resizing $VOLUME_ID from ${CURRENT_GB} GB to ${TARGET_GB} GB..."
  aws ec2 modify-volume --region "$EC2_REGION" --volume-id "$VOLUME_ID" --size "$TARGET_GB" >/dev/null
  echo "    Waiting for the EBS modification to apply..."
  while [ "$(aws ec2 describe-volumes-modifications --region "$EC2_REGION" \
      --volume-id "$VOLUME_ID" \
      --filters Name=modification-state,Values=optimizing,completed \
      --query "length(VolumesModifications)" --output text)" != "1" ]; do
    sleep 2
  done
  REBOOT_NEEDED=true
  echo -e "${GREEN}EBS volume expanded to ${TARGET_GB} GB${NC} (filesystem grows on reboot)"
fi

# ─── Install kubectl ───────────────────────────────────────────────────────

echo ""
echo "==> Installing kubectl..."
# Pin to the 1.33 channel to stay within kubectl's ±1 minor-version skew of the cluster
curl -sLO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable-1.33.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# ─── Install Helm ──────────────────────────────────────────────────────────

echo ""
echo "==> Installing Helm..."
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ─── Install Flux CLI ──────────────────────────────────────────────────────

echo ""
echo "==> Installing Flux CLI..."
curl -s https://fluxcd.io/install.sh | sudo bash

# ─── Install ArgoCD CLI ───────────────────────────────────────────────────

echo ""
echo "==> Installing ArgoCD CLI..."
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# ─── Install jq and envsubst ──────────────────────────────────────────────

echo ""
echo "==> Installing jq and envsubst..."
if command -v yum &>/dev/null; then
  sudo yum install -y jq gettext -q
elif command -v dnf &>/dev/null; then
  sudo dnf install -y jq gettext -q
fi

# ─── Connect to EKS ───────────────────────────────────────────────────────

echo ""
echo "==> Connecting to EKS cluster: $CLUSTER_NAME ($REGION)..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# ─── Set STUDENT_NAME in shell profile ─────────────────────────────────────

PROFILE="$HOME/.bashrc"
if ! grep -q "export STUDENT_NAME=" "$PROFILE" 2>/dev/null; then
  echo "export STUDENT_NAME=$STUDENT_NAME" >> "$PROFILE"
  echo "Added STUDENT_NAME to $PROFILE"
fi
export STUDENT_NAME

# ─── Verify everything ────────────────────────────────────────────────────

echo ""
echo "=== Tool Versions ==="
kubectl version --client --short 2>/dev/null || kubectl version --client
helm version --short
flux --version
argocd version --client --short 2>/dev/null || argocd version --client
jq --version
envsubst --version
git --version
docker --version
openssl version

echo ""
echo "=== Cluster Connectivity ==="
kubectl cluster-info
kubectl config current-context

echo ""
echo -e "${GREEN}=== Setup complete ===${NC}"
echo "Student: $STUDENT_NAME"
echo ""
echo "STUDENT_NAME has been added to ~/.bashrc so it persists across terminal sessions."
echo "For the current terminal, run: export STUDENT_NAME=$STUDENT_NAME"

if [ "$REBOOT_NEEDED" = true ]; then
  echo ""
  echo -e "${YELLOW}=== ACTION REQUIRED: reboot to apply the disk resize ===${NC}"
  echo "The root volume was expanded to ${TARGET_GB} GB. Run:"
  echo ""
  echo -e "    ${YELLOW}sudo reboot${NC}"
  echo ""
  echo "After it reboots (~1 min), reconnect — the filesystem will fill the 100 GB"
  echo "automatically. Your installed tools and kubeconfig persist across the reboot."
fi
