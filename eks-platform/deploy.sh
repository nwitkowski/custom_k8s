#!/bin/bash
###############################################################################
# Deterministic platform deploy (from clean state).
#
# Staged to avoid two known pitfalls on a fresh build:
#   1. Chicken-and-egg: the kubernetes/helm/flux providers can't connect until
#      the EKS cluster exists, so a single `apply` can't even plan them.
#   2. The aws-ebs-csi-driver addon references the ebs_csi IAM ROLE but not its
#      policy ATTACHMENT, so building only the cluster module leaves the CSI
#      controller without EC2 permissions (CrashLoop). We therefore include the
#      ebs_csi role + attachment + KMS policy in Stage 1.
#
# Usage:  AWS_PROFILE=org-root bash deploy.sh
###############################################################################
set -uo pipefail
cd "$(dirname "$0")/terraform"

REGION=$(grep -E '^aws_region' terraform.tfvars | sed 's/.*= *"//; s/".*//')
CLUSTER=$(grep -E '^cluster_name' terraform.tfvars | sed 's/.*= *"//; s/".*//')
echo "==> Deploying $CLUSTER in $REGION"

echo "==> Stage 1: VPC + EKS cluster + node group + EBS-CSI IAM"
terraform apply -auto-approve -input=false \
  -target=module.eks.module.vpc \
  -target=module.eks.module.eks \
  -target=module.eks.aws_iam_role.ebs_csi \
  -target=module.eks.aws_iam_role_policy_attachment.ebs_csi \
  -target=module.eks.aws_iam_role_policy.ebs_csi_kms

echo "==> Connecting kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

echo "==> Ensuring EBS-CSI controller is healthy (restart if it raced the IAM attach)"
for i in $(seq 1 20); do
  ready=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver --no-headers 2>/dev/null | grep controller | grep -c '6/6' || true)
  [ "${ready:-0}" -ge 1 ] && { echo "    controllers healthy"; break; }
  # Kick crashlooping controllers so they pick up the now-attached IAM policy.
  kubectl delete pod -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver --field-selector=status.phase!=Running &>/dev/null || true
  kubectl get pods -n kube-system -o name 2>/dev/null | grep ebs-csi-controller | xargs -r kubectl delete -n kube-system &>/dev/null || true
  sleep 12
done

echo "==> Stage 2: full apply (storage classes, metrics-server, Vault, Flux bootstrap, IRSA)"
terraform apply -auto-approve -input=false

echo "==> Waiting for Flux Kustomizations to reconcile (max 20m)"
for i in $(seq 1 120); do
  total=$(kubectl get kustomizations -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get kustomizations -A --no-headers 2>/dev/null | grep -c True || true)
  printf "\r    Kustomizations: %s/%s ready" "$ready" "$total"
  [ "${total:-0}" -gt 1 ] && [ "$ready" = "$total" ] && { echo " — done"; break; }
  sleep 10
done

echo "==> Waiting for HelmReleases (max 15m)"
for i in $(seq 1 90); do
  total=$(kubectl get helmreleases -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get helmreleases -A --no-headers 2>/dev/null | grep -c True || true)
  printf "\r    HelmReleases: %s/%s ready" "$ready" "$total"
  [ "${total:-0}" -gt 0 ] && [ "$ready" = "$total" ] && { echo " — done"; break; }
  sleep 10
done

echo ""
echo "==> Deploy complete. Cluster $CLUSTER ($REGION) ready."
kubectl get nodes
