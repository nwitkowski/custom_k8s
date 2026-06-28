#!/bin/bash
###############################################################################
# Platform Prerequisites Test
# Verifies tools, cluster access, and ALL platform components
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "=== Platform Prerequisites ==="
echo ""

# ─── Tools ──────────────────────────────────────────────────────────────────

echo "Tools:"
assert_cmd "kubectl installed" kubectl version --client
assert_cmd "helm installed" helm version --short
assert_cmd "flux installed" flux version --client
assert_cmd "argocd installed" argocd version --client
assert_cmd "jq installed" jq --version
assert_cmd "envsubst installed" envsubst --version
assert_cmd "git installed" git --version
assert_cmd "docker installed" docker --version
assert_cmd "aws cli installed" aws --version

# ─── Cluster Access ─────────────────────────────────────────────────────────

echo ""
echo "Cluster Access:"

CLUSTER_INFO=$(kubectl cluster-info 2>&1)
assert_contains "kubectl can reach cluster" "$CLUSTER_INFO" "is running at"

NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$NODES" -gt 0 ]; then
  pass "cluster has $NODES node(s)"
else
  fail "no nodes found"
fi

NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | sort -u)
assert_eq "all nodes Ready" "Ready" "$NODE_STATUS"

# ─── Helper: find running pods by name pattern across namespaces ───────────

# require_component — component MUST be running (fail if not found)
require_component() {
  local desc="$1" pattern="$2" ns="$3"

  local count
  count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -iE "$pattern" | grep -c Running || true)
  if [ "$count" -gt 0 ]; then
    pass "$desc ($count pods in $ns)"
    return 0
  fi

  # Try all namespaces as fallback
  count=$(kubectl get pods -A --no-headers 2>/dev/null | grep -iE "$pattern" | grep -c Running || true)
  if [ "$count" -gt 0 ]; then
    local found_ns
    found_ns=$(kubectl get pods -A --no-headers 2>/dev/null | grep -iE "$pattern" | grep Running | head -1 | awk '{print $1}')
    pass "$desc ($count pods in $found_ns)"
    return 0
  fi

  fail "$desc — not found"
  return 1
}

# ─── Flux Reconciliation ────────────────────────────────────────────────────

echo ""
echo "Flux GitOps:"

require_component "flux controllers running" "flux|source-controller|kustomize-controller" "flux-system"

# Flux Kustomizations
FLUX_KS=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$FLUX_KS" -gt 0 ]; then
  FLUX_KS_READY=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers 2>/dev/null | grep -c "True" || true)
  if [ "$FLUX_KS_READY" -eq "$FLUX_KS" ]; then
    pass "all $FLUX_KS Flux Kustomizations reconciled"
  else
    fail "$FLUX_KS_READY/$FLUX_KS Flux Kustomizations ready"
    kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers 2>/dev/null | grep -v "True" | awk '{printf "    ✗ %s/%s\n", $1, $2}'
  fi
else
  fail "no Flux Kustomizations found"
fi

# Flux HelmReleases
FLUX_HR=$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$FLUX_HR" -gt 0 ]; then
  FLUX_HR_READY=$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | grep -c "True" || true)
  if [ "$FLUX_HR_READY" -eq "$FLUX_HR" ]; then
    pass "all $FLUX_HR Flux HelmReleases ready"
  else
    fail "$FLUX_HR_READY/$FLUX_HR Flux HelmReleases ready"
    kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | grep -v "True" | awk '{printf "    ✗ %s/%s\n", $1, $2}'
  fi
else
  fail "no Flux HelmReleases found"
fi

# ─── Core Infrastructure ────────────────────────────────────────────────────

echo ""
echo "Core Infrastructure:"

# Metrics Server (Terraform-managed)
require_component "metrics-server running" "metrics-server" "kube-system"

if kubectl top nodes &>/dev/null 2>&1; then
  pass "kubectl top nodes works"
else
  fail "kubectl top not responding"
fi

# Cert-Manager
require_component "cert-manager running" "cert-manager" "cert-manager"

# StorageClasses
SC_COUNT=$(kubectl get storageclasses --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$SC_COUNT" -gt 0 ]; then
  pass "$SC_COUNT StorageClass(es) available"
else
  fail "no StorageClasses found"
fi

# ─── Networking ──────────────────────────────────────────────────────────────

echo ""
echo "Networking:"

# Calico
if kubectl get installation default &>/dev/null 2>&1; then
  pass "calico operator installed"
  # Check calico pods
  CALICO_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -iE "calico|tigera" | grep -c Running || true)
  if [ "$CALICO_PODS" -gt 0 ]; then
    pass "calico running ($CALICO_PODS pods)"
  else
    fail "calico installation exists but no pods running"
  fi
elif kubectl get pods -A --no-headers 2>/dev/null | grep -iE "calico|tigera" | grep -q Running; then
  pass "calico running"
else
  fail "calico not found — NetworkPolicy enforcement unavailable"
fi

# Ingress NGINX
require_component "ingress-nginx running" "ingress-nginx|nginx-controller" "ingress-nginx"

# Verify ingress controller has an external IP/hostname
INGRESS_SVC=$(kubectl get svc -n ingress-nginx -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$INGRESS_SVC" ]; then
  pass "ingress-nginx LoadBalancer has hostname"
elif INGRESS_IP=$(kubectl get svc -n ingress-nginx -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null) && [ -n "$INGRESS_IP" ]; then
  pass "ingress-nginx LoadBalancer has IP"
else
  skip "ingress-nginx LoadBalancer pending (may still be provisioning)"
fi

# Envoy Gateway
require_component "envoy-gateway running" "envoy-gateway" "envoy-gateway-system"

# Gateway API CRDs
if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null 2>&1; then
  pass "Gateway API CRDs installed"
else
  fail "Gateway API CRDs not found"
fi

# GatewayClass
if kubectl get gatewayclass eg &>/dev/null 2>&1; then
  pass "GatewayClass 'eg' exists"
else
  fail "GatewayClass 'eg' not found"
fi

# platform-gateway Gateway resource — not just the class. A usable Gateway is
# either Programmed (status condition) or has been assigned an address.
if kubectl get gateway platform-gateway -n envoy-gateway-system &>/dev/null 2>&1; then
  GW_PROGRAMMED=$(kubectl get gateway platform-gateway -n envoy-gateway-system \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  GW_ADDR=$(kubectl get gateway platform-gateway -n envoy-gateway-system \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
  if [ "$GW_PROGRAMMED" = "True" ] || [ -n "$GW_ADDR" ]; then
    pass "Gateway 'platform-gateway' is Programmed / has an address"
  else
    skip "Gateway 'platform-gateway' exists but not yet Programmed"
  fi
else
  skip "Gateway 'platform-gateway' not found"
fi

# ─── Security ────────────────────────────────────────────────────────────────

echo ""
echo "Security:"

# Kyverno
require_component "kyverno running" "kyverno" "kyverno"

# Kyverno policies
POLICY_COUNT=$(kubectl get clusterpolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$POLICY_COUNT" -gt 0 ]; then
  pass "$POLICY_COUNT ClusterPolicy(ies) installed"
else
  fail "no Kyverno ClusterPolicies found"
fi

# Expected ClusterPolicies from flux/policies — verify by name.
for POLICY in require-resource-limits require-team-label disallow-privileged require-run-as-non-root generate-resource-quota; do
  if kubectl get clusterpolicy "$POLICY" &>/dev/null 2>&1; then
    pass "ClusterPolicy '$POLICY' exists"
  else
    skip "ClusterPolicy '$POLICY' not found"
  fi
done

# External Secrets Operator
require_component "external-secrets-operator running" "external-secrets" "external-secrets"

# ClusterSecretStore
if kubectl get clustersecretstore &>/dev/null 2>&1; then
  CSS_COUNT=$(kubectl get clustersecretstore --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$CSS_COUNT" -gt 0 ]; then
    pass "ClusterSecretStore configured ($CSS_COUNT found)"
  else
    fail "ClusterSecretStore CRD exists but none configured"
  fi

  # vault-store should actively report Ready=True (validates the Vault auth
  # path, not just that the object was created).
  if kubectl get clustersecretstore vault-store &>/dev/null 2>&1; then
    CSS_READY=$(kubectl get clustersecretstore vault-store \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$CSS_READY" = "True" ]; then
      pass "ClusterSecretStore 'vault-store' reports Ready=True"
    else
      skip "ClusterSecretStore 'vault-store' not Ready yet (status: ${CSS_READY:-none})"
    fi
  else
    skip "ClusterSecretStore 'vault-store' not found"
  fi
else
  fail "ClusterSecretStore CRD not installed"
fi

# Vault
if kubectl get pods -A --no-headers 2>/dev/null | grep -i vault | grep -q Running; then
  VAULT_NS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -i vault | grep Running | head -1 | awk '{print $1}')
  VAULT_POD=$(kubectl get pods -n "$VAULT_NS" --no-headers 2>/dev/null | grep -i vault | grep Running | head -1 | awk '{print $1}')
  pass "vault running ($VAULT_NS/$VAULT_POD)"
  VAULT_STATUS=$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo "unknown")
  assert_eq "vault unsealed" "false" "$VAULT_STATUS"
else
  fail "vault not running"
fi

# ─── Monitoring ──────────────────────────────────────────────────────────────

echo ""
echo "Monitoring:"

require_component "prometheus running" "prometheus" "monitoring"
require_component "grafana running" "grafana" "monitoring"
require_component "alertmanager running" "alertmanager" "monitoring"

# Blackbox exporter
require_component "blackbox-exporter running" "blackbox" "monitoring"

# external-endpoints blackbox Probe CR (defines what blackbox actually probes)
if kubectl get probe external-endpoints -n monitoring &>/dev/null 2>&1; then
  pass "blackbox Probe 'external-endpoints' exists in monitoring namespace"
else
  skip "blackbox Probe 'external-endpoints' not found"
fi

# Jaeger (all-in-one tracing backend — deployed for the observability lab)
if kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -iE "jaeger" | grep -q Running; then
  JAEGER_POD=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -iE "jaeger" | grep Running | head -1 | awk '{print $1}')
  pass "jaeger running in monitoring namespace ($JAEGER_POD)"
else
  skip "jaeger not running in monitoring namespace"
fi

# ─── Logging ─────────────────────────────────────────────────────────────────

echo ""
echo "Logging:"

require_component "logging-operator running" "logging-operator" "logging"

# ─── GitOps ──────────────────────────────────────────────────────────────────

echo ""
echo "GitOps:"

# ArgoCD
require_component "argocd running" "argocd" "argocd"

if kubectl get crd applications.argoproj.io &>/dev/null 2>&1; then
  pass "ArgoCD Application CRD exists"
else
  fail "ArgoCD Application CRD not found"
fi

# ─── AWS Integration ────────────────────────────────────────────────────────

echo ""
echo "AWS Integration:"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -n "$AWS_ACCOUNT_ID" ]; then
  pass "AWS account accessible: $AWS_ACCOUNT_ID"
else
  fail "AWS account not accessible"
fi

BUCKET_CHECK=$(aws s3 ls s3://platform-lab-irsa-demo/ 2>&1)
if echo "$BUCKET_CHECK" | grep -q "test-file.txt"; then
  pass "IRSA demo S3 bucket accessible"
else
  fail "IRSA demo S3 bucket not accessible"
fi

# ─── Helm Releases ──────────────────────────────────────────────────────────

echo ""
echo "Helm Releases:"
HELM_COUNT=$(helm list -A --short 2>/dev/null | wc -l | tr -d ' ')
if [ "$HELM_COUNT" -gt 0 ]; then
  pass "$HELM_COUNT Helm release(s) deployed"
else
  fail "no Helm releases found"
fi

summary
