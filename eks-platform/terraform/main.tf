###############################################################################
# EKS Platform Stack — Terraform Root Module
# Terraform creates: EKS, IRSA roles, Vault (in-cluster), FluxCD bootstrap
# FluxCD manages:    All Helm releases and platform configuration
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.3"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # Uncomment for remote state
  # backend "s3" {
  #   bucket         = "my-terraform-state"
  #   key            = "eks-platform/terraform.tfstate"
  #   region         = "us-east-2"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}

# Authenticate to EKS with `aws eks get-token` via the exec plugin rather than a
# static data.aws_eks_cluster_auth token. The static token expires after ~15 min,
# which fails mid-apply (Unauthorized) because the cluster + node group build
# takes longer than that before these in-cluster resources are reached.

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--output", "json"]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--output", "json"]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--output", "json"]
  }
}

provider "github" {
  owner = var.github_owner
  token = var.github_token
}

provider "flux" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--output", "json"]
    }
  }
  git = {
    url = "ssh://git@github.com/${var.github_owner}/${var.flux_repository_name}.git"
    ssh = {
      username    = "git"
      private_key = tls_private_key.flux.private_key_pem
    }
  }
}

# ─── Modules ────────────────────────────────────────────────────────────────

module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  aws_region         = var.aws_region
  vpc_cidr           = var.vpc_cidr
  node_instance_type = var.node_instance_type
  node_desired       = var.node_desired
  node_min           = var.node_min
  node_max           = var.node_max
  student_role_name  = var.student_role_name
}

module "irsa" {
  source = "./modules/irsa"

  cluster_name              = module.eks.cluster_name
  cluster_oidc_provider_arn = module.eks.oidc_provider_arn
  cluster_oidc_provider_url = module.eks.oidc_provider_url
  domain_zone_id            = var.route53_zone_id
  enable_dns                = var.enable_dns
}

# ─── Metrics Server ─────────────────────────────────────────────────────────
# Installed via Terraform (not Flux) so kubectl top works immediately
# after cluster setup, before Flux finishes reconciling.

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.2"

  # EKS does not auto-approve kubelet *serving* CSRs, so the kubelet serving
  # certs can't be validated by metrics-server and it never completes a scrape
  # (pod stays NotReady -> metrics.k8s.io APIService has no endpoints ->
  # "Metrics API not available"). Skip kubelet cert verification.
  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [module.eks]
}

module "vault" {
  source = "./modules/vault"

  vault_root_token = var.vault_root_token

  depends_on = [module.eks]
}

module "flux_bootstrap" {
  source = "./modules/flux-bootstrap"

  github_owner        = var.github_owner
  github_token        = var.github_token
  repository_name     = var.flux_repository_name
  cluster_name        = var.cluster_name
  cluster_path        = "clusters/${var.cluster_name}"
  flux_ssh_public_key = tls_private_key.flux.public_key_openssh

  depends_on = [module.eks]
}

# ─── Flux SSH Key ───────────────────────────────────────────────────────────

resource "tls_private_key" "flux" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

# ─── Bootstrap Flux ────────────────────────────────────────────────────────

resource "flux_bootstrap_git" "this" {
  depends_on = [module.flux_bootstrap]

  path = "clusters/${var.cluster_name}"
}

# ─── Push Infrastructure Definitions to Flux Repo ────────────────────────────
# After Flux bootstrap, the git repo only has flux-system manifests.
# This pushes the full infrastructure definitions so Flux can reconcile them.

resource "null_resource" "flux_infrastructure" {
  depends_on = [flux_bootstrap_git.this]

  triggers = {
    # Re-run when infrastructure definitions change
    flux_dir_hash = sha1(join("", [
      for f in sort(fileset("${path.root}/../flux", "**")) :
      filesha1("${path.root}/../flux/${f}")
    ]))
  }

  provisioner "local-exec" {
    environment = {
      GITHUB_TOKEN = var.github_token
    }
    command = <<-EOT
      set -e

      TMPDIR=$(mktemp -d)
      trap "rm -rf $TMPDIR" EXIT

      # Clone the Flux repo — credential helper keeps the token out of argv/logs
      git -c credential.helper='!f() { echo "username=x-access-token"; echo "password=$GITHUB_TOKEN"; }; f' \
        clone "https://github.com/${var.github_owner}/${var.flux_repository_name}.git" "$TMPDIR/repo"

      # Copy infrastructure definitions
      rm -rf "$TMPDIR/repo/flux"
      cp -r "${path.root}/../flux" "$TMPDIR/repo/flux"

      # Create cluster infrastructure reference
      cp "${path.root}/../flux/infrastructure/kustomizations.yaml" \
         "$TMPDIR/repo/clusters/${var.cluster_name}/infrastructure.yaml"

      # Ensure the cluster kustomization.yaml includes infrastructure.yaml
      CLUSTER_KS="$TMPDIR/repo/clusters/${var.cluster_name}/kustomization.yaml"
      if [ -f "$CLUSTER_KS" ]; then
        if ! grep -q "infrastructure.yaml" "$CLUSTER_KS"; then
          echo "  - infrastructure.yaml" >> "$CLUSTER_KS"
        fi
      else
        cat > "$CLUSTER_KS" <<KUSTOMIZE
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - flux-system
  - infrastructure.yaml
KUSTOMIZE
      fi

      cd "$TMPDIR/repo"

      # Configure git
      git config user.email "terraform@platform-lab"
      git config user.name "Terraform"
      git config credential.helper '!f() { echo "username=x-access-token"; echo "password=$GITHUB_TOKEN"; }; f'

      git add -A
      if git diff --cached --quiet; then
        echo "No changes to push"
      else
        git commit -m "Add platform infrastructure definitions"
        git push
        echo "Infrastructure definitions pushed to Flux repo"
      fi
    EOT
  }
}
