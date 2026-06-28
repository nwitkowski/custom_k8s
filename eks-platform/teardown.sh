#!/bin/bash
###############################################################################
# Teardown the platform + cluster.
#
# Order matters: Kubernetes LoadBalancer Services (ingress-nginx, etc.) provision
# real AWS NLBs/CLBs that Terraform does NOT manage. If we destroy the cluster
# first, those load balancers are orphaned and their ENIs block VPC/subnet
# deletion — Terraform then retries DependencyViolation for ~30+ minutes.
#
# So we: (1) delete LoadBalancer Services while the cluster is still up and let
# the cloud controller deprovision their LBs, (2) sweep any orphaned LBs / VPC
# endpoints left in the platform-lab VPC, (3) terraform destroy. Re-runnable.
#
# Usage:  AWS_PROFILE=org-root bash teardown.sh
###############################################################################
set -uo pipefail
cd "$(dirname "$0")/terraform"

REGION=$(grep -E '^aws_region'  terraform.tfvars | sed 's/.*= *"//; s/".*//')
CLUSTER=$(grep -E '^cluster_name' terraform.tfvars | sed 's/.*= *"//; s/".*//')

# ─── 1. Delete LoadBalancer Services so their NLBs/CLBs deprovision ──────────
if kubectl get nodes &>/dev/null; then
  echo "==> Deleting LoadBalancer Services (releases their NLBs/CLBs)"
  kubectl get svc -A \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while IFS=/ read -r ns name; do
        [ -n "$name" ] && echo "    deleting svc $ns/$name" && kubectl delete svc "$name" -n "$ns" --wait=false &>/dev/null
      done
  echo "    waiting 90s for the cloud controller to remove the load balancers..."
  sleep 90
else
  echo "==> Cluster API unreachable — skipping LoadBalancer Service deletion"
fi

# ─── 2. Sweep any orphaned LBs / VPC endpoints in the platform-lab VPC ───────
VPC=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=*${CLUSTER}*" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [ -n "$VPC" ] && [ "$VPC" != "None" ]; then
  echo "==> Sweeping orphaned load balancers / endpoints in $VPC"
  for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" --output text 2>/dev/null); do
    echo "    deleting NLB/ALB $arn"; aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" &>/dev/null || true
  done
  for name in $(aws elb describe-load-balancers --region "$REGION" \
      --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" --output text 2>/dev/null); do
    echo "    deleting classic ELB $name"; aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$name" &>/dev/null || true
  done
  EPS=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null)
  [ -n "$EPS" ] && aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids $EPS &>/dev/null || true
  echo "    waiting 30s for ENIs to release..."
  sleep 30
  # Orphaned k8s-elb-* security groups (left behind when a classic LB is deleted
  # abruptly) also block VPC deletion — remove them once their ENIs are gone.
  for sg in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=k8s-elb-*" \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null); do
    echo "    deleting orphaned LB security group $sg"
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" &>/dev/null || true
  done
fi

# ─── 3. terraform destroy (with state-surgery fallback) ─────────────────────
echo "==> terraform destroy"
if terraform destroy -auto-approve -input=false; then
  echo "==> Destroy complete."
  exit 0
fi

echo "==> Clean destroy failed (cluster API likely unreachable). Removing cluster-API-bound resources from state, then destroying AWS infra."
for addr in \
  flux_bootstrap_git.this \
  helm_release.metrics_server \
  module.vault.helm_release.vault \
  module.vault.kubectl_manifest.vault_bootstrap \
  module.eks.kubernetes_annotations.remove_gp2_default \
  module.eks.kubernetes_storage_class.gp3_encrypted \
  module.eks.kubernetes_storage_class.gp3_encrypted_immediate \
  module.eks.kubernetes_storage_class.gp3_encrypted_retain \
  module.eks.kubernetes_storage_class.io2_encrypted; do
  terraform state rm "$addr" 2>/dev/null && echo "    removed $addr" || true
done

echo "==> Re-running destroy on remaining AWS resources"
terraform destroy -auto-approve -input=false
echo "==> Destroy complete (after state surgery)."
