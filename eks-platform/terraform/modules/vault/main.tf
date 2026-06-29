###############################################################################
# Vault Module — In-Cluster Dev Mode + Bootstrap
###############################################################################

terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }
}

variable "vault_root_token" {
  description = "Vault dev root token"
  type        = string
  default     = "root"
  sensitive   = true
}

resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  namespace        = "vault"
  create_namespace = true

  set {
    name  = "server.dev.enabled"
    value = "true"
  }

  set {
    name  = "server.dev.devRootToken"
    value = var.vault_root_token
  }

  set {
    name  = "injector.enabled"
    value = "false"
  }

  set {
    name  = "server.resources.requests.memory"
    value = "256Mi"
  }

  set {
    name  = "server.resources.requests.cpu"
    value = "250m"
  }
}

# ─── Bootstrap Job ──────────────────────────────────────────────────────────
# Runs a one-shot Job to configure Vault after it's ready:
#   - Enable KV v2
#   - Seed sample secrets
#   - Enable and configure Kubernetes auth
#   - Create policy and role for ESO

resource "kubectl_manifest" "vault_bootstrap" {
  depends_on = [helm_release.vault]

  yaml_body = <<-YAML
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: vault-bootstrap
      namespace: vault
    spec:
      backoffLimit: 5
      template:
        spec:
          serviceAccountName: vault
          restartPolicy: OnFailure
          initContainers:
            - name: wait-for-vault
              image: busybox:1.36
              command: ['sh', '-c', 'until wget -qO- http://vault.vault.svc:8200/v1/sys/health; do sleep 2; done']
          containers:
            - name: bootstrap
              image: hashicorp/vault:1.17
              env:
                - name: VAULT_ADDR
                  value: "http://vault.vault.svc:8200"
                - name: VAULT_TOKEN
                  value: "${var.vault_root_token}"
              command:
                - /bin/sh
                - -c
                - |
                  set -e

                  echo "==> Enabling KV v2 at secret/"
                  vault secrets enable -path=secret kv-v2 || true

                  echo "==> Seeding sample secrets"
                  vault kv put secret/prod/database \
                    username=appuser \
                    password='S3cur3P@ss!' \
                    host=db.internal.local

                  vault kv put secret/prod/api \
                    key=ak_live_xxxxxxxxxxxx

                  echo "==> Enabling Kubernetes auth"
                  vault auth enable kubernetes || true

                  vault write auth/kubernetes/config \
                    kubernetes_host="https://kubernetes.default.svc.cluster.local:443"

                  echo "==> Creating ESO policy"
                  vault policy write eso-read - <<POLICY
                  path "secret/data/*" {
                    capabilities = ["read"]
                  }
                  path "secret/metadata/*" {
                    capabilities = ["list", "read"]
                  }
                  POLICY

                  echo "==> Creating ESO role"
                  vault write auth/kubernetes/role/external-secrets \
                    bound_service_account_names=external-secrets-sa \
                    bound_service_account_namespaces=external-secrets \
                    policies=eso-read \
                    ttl=1h

                  echo "==> Vault bootstrap complete"
  YAML
}

# Dev-mode Vault uses in-memory storage, so any pod restart (node roll, scaling,
# upgrade) wipes its auth method + seeded secrets and breaks the ESO ClusterSecretStore.
# This CronJob re-runs the (idempotent) bootstrap every 2 minutes so Vault self-heals.
# NOTE: the durable fix is standalone Vault + a PVC + AWS KMS auto-unseal.
resource "kubectl_manifest" "vault_reseal_cron" {
  depends_on = [helm_release.vault]

  yaml_body = <<-YAML
    apiVersion: batch/v1
    kind: CronJob
    metadata:
      name: vault-reseal-bootstrap
      namespace: vault
    spec:
      schedule: "*/2 * * * *"
      concurrencyPolicy: Forbid
      successfulJobsHistoryLimit: 1
      failedJobsHistoryLimit: 2
      startingDeadlineSeconds: 60
      jobTemplate:
        spec:
          backoffLimit: 1
          ttlSecondsAfterFinished: 120
          template:
            spec:
              serviceAccountName: vault
              restartPolicy: OnFailure
              initContainers:
                - name: wait-for-vault
                  image: busybox:1.36
                  command: ['sh', '-c', 'until wget -qO- http://vault.vault.svc:8200/v1/sys/health; do sleep 2; done']
              containers:
                - name: bootstrap
                  image: hashicorp/vault:1.17
                  env:
                    - name: VAULT_ADDR
                      value: "http://vault.vault.svc:8200"
                    - name: VAULT_TOKEN
                      value: "${var.vault_root_token}"
                  command:
                    - /bin/sh
                    - -c
                    - |
                      set -e
                      vault secrets enable -path=secret kv-v2 || true
                      vault kv put secret/prod/database \
                        username=appuser password='S3cur3P@ss!' host=db.internal.local
                      vault kv put secret/prod/api key=ak_live_xxxxxxxxxxxx
                      vault auth enable kubernetes || true
                      vault write auth/kubernetes/config \
                        kubernetes_host="https://kubernetes.default.svc.cluster.local:443"
                      vault policy write eso-read - <<POLICY
                      path "secret/data/*" {
                        capabilities = ["read"]
                      }
                      path "secret/metadata/*" {
                        capabilities = ["list", "read"]
                      }
                      POLICY
                      vault write auth/kubernetes/role/external-secrets \
                        bound_service_account_names=external-secrets-sa \
                        bound_service_account_namespaces=external-secrets \
                        policies=eso-read ttl=1h
  YAML
}
