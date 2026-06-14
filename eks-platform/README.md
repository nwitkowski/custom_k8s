# Instructor Setup — Intermediate Kubernetes Course

---

## Step 1: Deploy the EKS Cluster

### Prerequisites

- AWS CLI v2, Terraform >= 1.5, kubectl, Flux CLI
- GitHub PAT with `repo` scope

### Configure and Deploy

```bash
cd eks-platform/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

export TF_VAR_github_token="ghp_your_token_here"

terraform init
terraform plan
terraform apply
```

Terraform creates:
- EKS cluster, VPC, managed node group
- Student IAM role (`k8s-lab-role`) with EC2 trust + AdministratorAccess
- Instance profile for Cloud9 attachment
- EKS access entry granting the student role cluster-admin
- IRSA roles, Vault, Flux bootstrap

### Connect

```bash
aws eks update-kubeconfig --name platform-lab --region us-east-2
```

---

## Step 2: Verify Flux

Wait 5-10 minutes after deploy, then:

```bash
flux get kustomizations
```

All should show `Ready: True`.

---

## Step 3: Post-Deploy Configuration

### Update IRSA ARNs (only if `enable_dns = true`)

> **Skip this step with the default configuration.** `enable_dns` defaults to `false`, and `terraform output irsa_roles` prints placeholder text instead of ARNs. The cert-manager and external-dns IRSA roles are only created when `enable_dns = true` is set in `terraform.tfvars` along with `route53_zone_id` and `domain`.

If DNS is enabled:

```bash
terraform output irsa_roles
```

Update (and uncomment) the ARNs in:
- `flux/infrastructure/core/core.yaml` → cert-manager
- `flux/infrastructure/networking/networking.yaml` → external-dns

Commit and push.

### Configure Splunk HEC Token

```bash
kubectl port-forward svc/splunk 8000:8000 -n splunk
# http://localhost:8000 — admin / Chang3Me!
# Settings > Data Inputs > HTTP Event Collector > New Token
# Name: kubernetes | Index: main | Source Type: _json

kubectl create secret generic splunk-hec-token \
  -n logging --from-literal=token=YOUR_HEC_TOKEN
```

---

## Step 4: Verify Platform Components

```bash
terraform output student_role_name        # Should print: k8s-lab-role
terraform output student_instance_profile # Should print: k8s-lab-role

kubectl top nodes                                    # Metrics Server
kubectl get installation default                     # Calico
kubectl get pods -n ingress-nginx                    # NGINX Ingress
kubectl get pods -n envoy-gateway-system             # Envoy Gateway
kubectl get crd | grep gateway                       # Gateway API CRDs
kubectl get pods -n cert-manager                     # cert-manager
kubectl get pods -n monitoring                       # Prometheus + Grafana + Jaeger + Blackbox
kubectl get pods -n kyverno                          # Kyverno
kubectl get clusterpolicy                            # Kyverno policies
kubectl get pods -n argocd                           # ArgoCD
kubectl get pods -n flux-system                      # Flux
kubectl get pods -n vault                            # Vault
kubectl exec -n vault vault-0 -- vault status
kubectl get pods -n external-secrets                 # ESO
kubectl get clustersecretstore                       # Vault integration
kubectl get pods -n logging                          # logging-operator + fluent-bit
kubectl get pods -n splunk                           # Splunk
aws s3 ls s3://platform-lab-irsa-demo/               # IRSA demo bucket
```

> ⚠️ **Vault runs in dev mode (in-memory).** If the `vault-0` pod restarts, all seeded
> lab secrets are lost. Re-run the bootstrap Job to re-seed them:
> `kubectl get job vault-bootstrap -n vault -o yaml | kubectl replace --force -f -`

---

## Monitoring Access

```bash
# Grafana — admin / admin
kubectl port-forward svc/monitoring-kube-prometheus-stack-grafana 3000:80 -n monitoring

# Prometheus
kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring

# Vault — Token: root
kubectl port-forward svc/vault 8200:8200 -n vault
```

---

## Teardown (after course)

```bash
cd eks-platform/terraform
terraform destroy
```

> Terraform handles full cleanup including the student IAM role, instance profile, and EKS access entry.
