#!/bin/bash
###############################################################################
# Lab 1 Test: Exploring Your Kubernetes Cluster
# Covers: cluster navigation, deploy/expose, pod inspection, scale,
#         port-forward, resource usage (kubectl top), tool versions
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab01-$STUDENT_NAME"
echo "=== Lab 1: Cluster Exploration (ns: $NS) ==="
echo ""

# ─── Tool version checks ──────────────────────────────────────────────────

echo "Tool Versions:"
assert_cmd "kubectl is available"   kubectl version --client
assert_cmd "helm is available"      helm version --short
assert_cmd "jq is available"        jq --version

# Step 3: required CLI tools (envsubst, git, openssl pre-installed; docker optional)
assert_cmd "envsubst installed"     command -v envsubst
assert_cmd "git installed"          command -v git
assert_cmd "openssl installed"      command -v openssl

if command -v docker &>/dev/null; then
  pass "docker installed"
else
  skip "docker not installed"
fi

if flux --version &>/dev/null; then
  pass "flux CLI is available"
else
  skip "flux CLI not installed"
fi

if argocd version --client &>/dev/null; then
  pass "argocd CLI is available"
else
  skip "argocd CLI not installed"
fi

# ─── Cluster navigation (Step 5 & 6) ──────────────────────────────────────

echo ""
echo "Cluster Navigation:"

# Step 4: cluster connectivity and active context
assert_cmd "kubectl cluster-info succeeds" kubectl cluster-info
CURRENT_CTX=$(kubectl config current-context 2>/dev/null)
assert_cmd "kubectl config current-context is non-empty" test -n "$CURRENT_CTX"

NODES=$(kubectl get nodes -o wide --no-headers 2>/dev/null)
assert_contains "nodes listed with wide output" "$NODES" "Ready"

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
NODE_DESC=$(kubectl describe node "$NODE_NAME" 2>/dev/null)
assert_contains "node describe shows kubelet info" "$NODE_DESC" "Kubelet Version"

# Step 5: describe nodes exposes a Taints: line
assert_contains "node describe shows Taints line" "$NODE_DESC" "Taints:"

LABELS=$(kubectl get nodes --show-labels --no-headers 2>/dev/null)
assert_contains "node labels visible" "$LABELS" "kubernetes.io"

NS_LIST=$(kubectl get namespaces --no-headers 2>/dev/null)
assert_contains "namespaces listed" "$NS_LIST" "kube-system"

SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$SYSTEM_PODS" -gt 0 ]; then
  pass "kube-system has $SYSTEM_PODS pods"
else
  fail "no pods in kube-system"
fi

ALL_RES=$(kubectl get all -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$ALL_RES" -gt 0 ]; then
  pass "kubectl get all -A returns $ALL_RES resources"
else
  fail "kubectl get all -A returned nothing"
fi

# Step 6: api-resources lists the API surface
API_RES=$(kubectl api-resources --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$API_RES" -gt 0 ]; then
  pass "kubectl api-resources returns $API_RES rows"
else
  fail "kubectl api-resources returned nothing"
fi

# ─── Deploy nginx (Step 7) ────────────────────────────────────────────────

echo ""
echo "Application Deployment:"
kubectl create namespace "$NS" &>/dev/null
kubectl create deployment nginx-lab --image=nginx:1.25 --replicas=2 -n "$NS" &>/dev/null
kubectl expose deployment nginx-lab --port=80 --target-port=80 -n "$NS" &>/dev/null

wait_for_deploy "$NS" nginx-lab 90
READY=$(kubectl get deployment nginx-lab -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "deployment has 2 ready replicas" "2" "$READY"

SVC=$(kubectl get svc nginx-lab -n "$NS" -o jsonpath='{.spec.type}' 2>/dev/null)
assert_eq "service type is ClusterIP" "ClusterIP" "$SVC"

SVC_PORT=$(kubectl get svc nginx-lab -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "service port is 80" "80" "$SVC_PORT"

ALL_NS=$(kubectl get all -n "$NS" --no-headers 2>/dev/null)
assert_contains "namespace has deployment resources" "$ALL_NS" "nginx-lab"

# ─── Pod inspection (Step 8) ──────────────────────────────────────────────

echo ""
echo "Pod Inspection:"
POD=$(kubectl get pods -n "$NS" -l app=nginx-lab -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

DESCRIBE=$(kubectl describe pod "$POD" -n "$NS" 2>/dev/null)
assert_contains "pod describe shows image" "$DESCRIBE" "nginx:1.25"
assert_contains "pod describe shows container state" "$DESCRIBE" "State:"

LOGS=$(kubectl logs "$POD" -n "$NS" --tail=5 2>&1)
assert_cmd "pod logs accessible" test -n "$LOGS"

EXEC_RESULT=$(kubectl exec "$POD" -n "$NS" -- cat /usr/share/nginx/html/index.html 2>/dev/null)
assert_contains "exec cat returns nginx welcome page" "$EXEC_RESULT" "Welcome to nginx"

EXEC_CONF=$(kubectl exec "$POD" -n "$NS" -- cat /etc/nginx/nginx.conf 2>/dev/null)
assert_contains "nginx.conf readable inside container" "$EXEC_CONF" "worker_processes"

# ─── Scale (Step 9) ───────────────────────────────────────────────────────

echo ""
echo "Scaling:"
kubectl scale deployment nginx-lab --replicas=5 -n "$NS" &>/dev/null
if wait_for_pods "$NS" "app=nginx-lab" 5 60; then
  pass "scaled up to 5 running pods"
else
  fail "scale up to 5 pods did not complete in time"
fi

kubectl scale deployment nginx-lab --replicas=2 -n "$NS" &>/dev/null
sleep 45
PODS_2=$(kubectl get pods -n "$NS" -l app=nginx-lab --no-headers 2>/dev/null | grep -c Running || true)
assert_eq "scaled down to 2 running pods" "2" "$PODS_2"

# ─── Port-forward (Step 10) ──────────────────────────────────────────────

echo ""
echo "Port-Forward:"
LOCAL_PORT=$((30000 + ($$ % 10000)))
kubectl port-forward svc/nginx-lab ${LOCAL_PORT}:80 -n "$NS" &>/dev/null &
PF_PID=$!

# Poll until the forward serves the nginx page (racy under parallel load).
CURL_BODY=""; CURL_HEADERS=""
for _i in $(seq 1 20); do
  CURL_BODY=$(curl -s --max-time 3 http://localhost:${LOCAL_PORT} 2>/dev/null)
  if echo "$CURL_BODY" | grep -q "Welcome to nginx"; then
    CURL_HEADERS=$(curl -sI --max-time 3 http://localhost:${LOCAL_PORT} 2>/dev/null)
    break
  fi
  sleep 1
done

kill $PF_PID 2>/dev/null
wait $PF_PID 2>/dev/null

assert_contains "port-forward curl returns nginx page" "$CURL_BODY" "Welcome to nginx"
assert_contains "port-forward HEAD returns 200" "$CURL_HEADERS" "200"

# ─── Resource usage (Step 11) ────────────────────────────────────────────

echo ""
echo "Resource Usage:"
METRICS_SERVER=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep metrics-server || true)
if [ -n "$METRICS_SERVER" ]; then
  TOP_NODES=$(kubectl top nodes --no-headers 2>/dev/null || true)
  if [ -n "$TOP_NODES" ]; then
    pass "kubectl top nodes returns data"
  else
    skip "kubectl top nodes returned no data (metrics may need time)"
  fi

  TOP_PODS=$(kubectl top pods -n "$NS" --no-headers 2>/dev/null || true)
  if [ -n "$TOP_PODS" ]; then
    pass "kubectl top pods returns data"
  else
    skip "kubectl top pods returned no data (metrics may need time)"
  fi
else
  skip "metrics-server not running — skipping kubectl top nodes"
  skip "metrics-server not running — skipping kubectl top pods"
fi

# ─── Cleanup (Step 12) ──────────────────────────────────────────────────

cleanup_ns "$NS"

# Step 12: confirm the namespace is gone (allow for terminating delay)
for i in $(seq 1 12); do
  kubectl get namespace "$NS" &>/dev/null || break
  sleep 5
done
assert_cmd_fails "lab namespace deleted after cleanup" kubectl get namespace "$NS"

summary
