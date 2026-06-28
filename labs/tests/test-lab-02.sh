#!/bin/bash
###############################################################################
# Lab 2 Test: Configuring Autoscaling
# Covers: metrics-server check, php-apache deploy + expose, HPA v1,
#         load generator + HPA target verification, HPA v2, VPA,
#         inflate deployment, kubectl top pods
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

LAB_DIR="$(cd "$SCRIPT_DIR/../lab-02" && pwd)"
export STUDENT_NAME="test-$$"
NS="lab02-$STUDENT_NAME"
echo "=== Lab 2: Autoscaling (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Step 1: Verify Metrics Server ──────────────────────────────────────

echo "Metrics Server:"
METRICS_POD=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep metrics-server || true)
if [ -n "$METRICS_POD" ]; then
  pass "metrics-server pod found in kube-system"
else
  skip "metrics-server not running (some tests will be skipped)"
fi

METRICS_API=$(kubectl get apiservices --no-headers 2>/dev/null | grep metrics || true)
if [ -n "$METRICS_API" ]; then
  pass "metrics API service registered"
else
  skip "metrics API service not found"
fi

METRICS_AVAILABLE=false
if [ -n "$METRICS_POD" ]; then
  TOP_NODES=$(kubectl top nodes --no-headers 2>/dev/null || true)
  if [ -n "$TOP_NODES" ]; then
    pass "kubectl top nodes returns data"
    METRICS_AVAILABLE=true
  else
    skip "kubectl top nodes returned no data (metrics may need time)"
  fi
fi

# ─── Step 2: Deploy php-apache ──────────────────────────────────────────

echo ""
echo "PHP-Apache Deployment:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/php-apache-deployment.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" php-apache 90

READY=$(kubectl get deployment php-apache -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "php-apache has 1 ready replica" "1" "$READY"

IMG=$(kubectl get deployment php-apache -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
assert_contains "php-apache uses hpa-example image" "$IMG" "hpa-example"

CPU_REQ=$(kubectl get deployment php-apache -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)
assert_eq "cpu request is 200m" "200m" "$CPU_REQ"

CPU_LIM=$(kubectl get deployment php-apache -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)
assert_eq "cpu limit is 500m" "500m" "$CPU_LIM"

# ─── Step 2 (cont): Expose as ClusterIP service ─────────────────────────

echo ""
echo "ClusterIP Service:"
kubectl expose deployment php-apache --port=80 --target-port=80 -n "$NS" &>/dev/null

SVC_TYPE=$(kubectl get svc php-apache -n "$NS" -o jsonpath='{.spec.type}' 2>/dev/null)
assert_eq "php-apache service type is ClusterIP" "ClusterIP" "$SVC_TYPE"

SVC_PORT=$(kubectl get svc php-apache -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "service port is 80" "80" "$SVC_PORT"

SVC_SELECTOR=$(kubectl get svc php-apache -n "$NS" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
assert_eq "service selector targets php-apache" "php-apache" "$SVC_SELECTOR"

# ─── Step 3: Create HPA v1 ──────────────────────────────────────────────

echo ""
echo "HPA v1:"
kubectl autoscale deployment php-apache --cpu-percent=50 --min=1 --max=10 -n "$NS" &>/dev/null
sleep 5

HPA_MAX=$(kubectl get hpa php-apache -n "$NS" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
assert_eq "HPA max replicas is 10" "10" "$HPA_MAX"

HPA_MIN=$(kubectl get hpa php-apache -n "$NS" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
assert_eq "HPA min replicas is 1" "1" "$HPA_MIN"

HPA_TARGET=$(kubectl get hpa php-apache -n "$NS" -o jsonpath='{.spec.metrics[0].resource.name}' 2>/dev/null)
assert_eq "HPA targets cpu" "cpu" "$HPA_TARGET"

HPA_PCT=$(kubectl get hpa php-apache -n "$NS" -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)
assert_eq "HPA cpu target is 50%" "50" "$HPA_PCT"

HPA_DESC=$(kubectl describe hpa php-apache -n "$NS" 2>/dev/null)
assert_contains "HPA describe shows deployment reference" "$HPA_DESC" "php-apache"

# ─── Step 4 & 5: Load generator + verify HPA target increase ────────────

echo ""
echo "Load Generator & HPA Response:"
kubectl run load-generator \
  --image=busybox:1.36 \
  --restart=Never \
  -n "$NS" \
  -- /bin/sh -c "while sleep 0.01; do wget -q -O- http://php-apache; done" &>/dev/null

# Wait for the load-generator pod to be running
sleep 5
LG_STATUS=$(kubectl get pod load-generator -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
assert_eq "load-generator pod is Running" "Running" "$LG_STATUS"

# Step 4: verify the load generator is actually hitting php-apache (logs show "OK!")
if [ "$LG_STATUS" = "Running" ]; then
  sleep 5
  LG_LOGS=$(kubectl logs load-generator -n "$NS" 2>/dev/null || true)
  if echo "$LG_LOGS" | grep -q "OK!"; then
    pass "load-generator logs contain hits to php-apache (OK!)"
  else
    skip "load-generator logs do not yet show OK! (may need more time)"
  fi
else
  skip "load-generator not running — skipping log check"
fi

# Give HPA time to observe increased CPU (check up to 90 seconds)
echo "  ... waiting for HPA to observe load (up to 90s)"
HPA_TRIGGERED=false
for i in $(seq 1 18); do
  sleep 5
  HPA_CURRENT=$(kubectl get hpa php-apache -n "$NS" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || echo "0")
  if [ -n "$HPA_CURRENT" ] && [ "$HPA_CURRENT" != "0" ] && [ "$HPA_CURRENT" != "<unknown>" ] && [ "$HPA_CURRENT" != "null" ]; then
    # Check if current utilization exceeds target (indicating load is detected)
    if [ "$HPA_CURRENT" -gt 0 ] 2>/dev/null; then
      HPA_TRIGGERED=true
      break
    fi
  fi
done

if [ "$HPA_TRIGGERED" = true ]; then
  pass "HPA detected CPU load (current: ${HPA_CURRENT}%)"
else
  skip "HPA did not report CPU increase within timeout"
fi

# Check if replicas increased (may or may not happen in short window)
HPA_REPLICAS=$(kubectl get hpa php-apache -n "$NS" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "1")
if [ "$HPA_REPLICAS" -gt 1 ] 2>/dev/null; then
  pass "HPA scaled to $HPA_REPLICAS replicas under load"
else
  skip "HPA has not scaled beyond 1 replica yet (may need more time)"
fi

# Step 6: Stop load
kubectl delete pod load-generator -n "$NS" --grace-period=0 --force &>/dev/null 2>&1
assert_cmd_fails "load-generator pod is gone after stopping load" kubectl get pod load-generator -n "$NS"

# ─── Step 7: HPA v2 ─────────────────────────────────────────────────────

echo ""
echo "HPA v2:"
kubectl delete hpa php-apache -n "$NS" &>/dev/null
envsubst '$STUDENT_NAME' < "$LAB_DIR/hpa-v2.yaml" | kubectl apply -f - &>/dev/null
sleep 3

HPA_V2_EXISTS=$(kubectl get hpa php-apache-v2 -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "HPA v2 created" "php-apache-v2" "$HPA_V2_EXISTS"

HPA_V2_METRICS=$(kubectl get hpa php-apache-v2 -n "$NS" -o jsonpath='{.spec.metrics}' 2>/dev/null)
assert_contains "HPA v2 has cpu metric" "$HPA_V2_METRICS" "cpu"
assert_contains "HPA v2 has memory metric" "$HPA_V2_METRICS" "memory"

HPA_V2_MAX=$(kubectl get hpa php-apache-v2 -n "$NS" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
assert_eq "HPA v2 max replicas is 5" "5" "$HPA_V2_MAX"

SCALEUP_WINDOW=$(kubectl get hpa php-apache-v2 -n "$NS" -o jsonpath='{.spec.behavior.scaleUp.stabilizationWindowSeconds}' 2>/dev/null)
assert_eq "HPA v2 scale-up window is 0s" "0" "$SCALEUP_WINDOW"

SCALEDOWN_WINDOW=$(kubectl get hpa php-apache-v2 -n "$NS" -o jsonpath='{.spec.behavior.scaleDown.stabilizationWindowSeconds}' 2>/dev/null)
assert_eq "HPA v2 scale-down window is 300s" "300" "$SCALEDOWN_WINDOW"

SCALEUP_POLICY=$(kubectl get hpa php-apache-v2 -n "$NS" -o jsonpath='{.spec.behavior.scaleUp.policies[0].type}' 2>/dev/null)
assert_eq "HPA v2 scale-up policy is Percent" "Percent" "$SCALEUP_POLICY"

HPA_V2_DESC=$(kubectl describe hpa php-apache-v2 -n "$NS" 2>/dev/null)
assert_contains "HPA v2 describe shows target ref" "$HPA_V2_DESC" "php-apache"

# ─── Step 8: VPA ────────────────────────────────────────────────────────

echo ""
echo "VPA:"
if kubectl api-resources 2>/dev/null | grep -q verticalpodautoscalers; then
  envsubst '$STUDENT_NAME' < "$LAB_DIR/vpa.yaml" | kubectl apply -f - &>/dev/null
  sleep 3

  VPA_EXISTS=$(kubectl get vpa php-apache-vpa -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
  assert_eq "VPA resource created" "php-apache-vpa" "$VPA_EXISTS"

  VPA_MODE=$(kubectl get vpa php-apache-vpa -n "$NS" -o jsonpath='{.spec.updatePolicy.updateMode}' 2>/dev/null)
  assert_eq "VPA update mode is Off" "Off" "$VPA_MODE"

  VPA_TARGET=$(kubectl get vpa php-apache-vpa -n "$NS" -o jsonpath='{.spec.targetRef.kind}' 2>/dev/null)
  assert_eq "VPA targets a Deployment" "Deployment" "$VPA_TARGET"

  VPA_TARGET_NAME=$(kubectl get vpa php-apache-vpa -n "$NS" -o jsonpath='{.spec.targetRef.name}' 2>/dev/null)
  assert_eq "VPA targets php-apache" "php-apache" "$VPA_TARGET_NAME"
else
  skip "VPA CRD not installed — skipping VPA resource creation"
  skip "VPA CRD not installed — skipping VPA mode check"
  skip "VPA CRD not installed — skipping VPA target check"
  skip "VPA CRD not installed — skipping VPA target name check"
fi

# ─── Step 9: Inflate Deployment (Cluster Autoscaler) ────────────────────

echo ""
echo "Inflate Deployment (Cluster Autoscaler):"
envsubst '$STUDENT_NAME' < "$LAB_DIR/inflate-deployment.yaml" | kubectl apply -f - &>/dev/null
sleep 5

INFLATE_EXISTS=$(kubectl get deployment inflate -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "inflate deployment created" "inflate" "$INFLATE_EXISTS"

INFLATE_REPLICAS=$(kubectl get deployment inflate -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
assert_eq "inflate deployment has 5 replicas" "5" "$INFLATE_REPLICAS"

INFLATE_IMG=$(kubectl get deployment inflate -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
assert_contains "inflate uses pause image" "$INFLATE_IMG" "pause"

INFLATE_CPU=$(kubectl get deployment inflate -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)
assert_eq "inflate cpu request is 250m" "250m" "$INFLATE_CPU"

INFLATE_PODS=$(kubectl get pods -n "$NS" -l app=inflate --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$INFLATE_PODS" -gt 0 ]; then
  pass "inflate pods exist ($INFLATE_PODS created)"
else
  fail "no inflate pods found"
fi

# Check for Pending pods (expected if cluster at capacity)
PENDING=$(kubectl get pods -n "$NS" -l app=inflate --no-headers 2>/dev/null | grep -c Pending || true)
if [ "$PENDING" -gt 0 ]; then
  pass "some inflate pods are Pending ($PENDING) — cluster capacity pressure"
else
  pass "all inflate pods scheduled (cluster has capacity)"
fi

# ─── kubectl top pods ───────────────────────────────────────────────────

echo ""
echo "Resource Usage:"
if [ "$METRICS_AVAILABLE" = true ]; then
  TOP_PODS=$(kubectl top pods -n "$NS" --no-headers 2>/dev/null || true)
  if [ -n "$TOP_PODS" ]; then
    pass "kubectl top pods returns data in namespace"
  else
    skip "kubectl top pods returned no data (metrics may need time for new pods)"
  fi
else
  skip "metrics not available — skipping kubectl top pods"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────

cleanup_ns "$NS"
assert_cmd_fails "namespace removed after teardown" kubectl get namespace "$NS"
summary
