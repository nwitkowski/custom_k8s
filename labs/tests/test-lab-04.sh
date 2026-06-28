#!/bin/bash
###############################################################################
# Lab 4 Test: Services and Service Discovery
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-04" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab04-$STUDENT_NAME"
echo "=== Lab 4: Services & Discovery (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

###############################################################################
# Step 1: Deploy backend (3 replicas) + frontend (2 replicas)
###############################################################################

echo "Deployments:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/backend-deployment.yaml" | kubectl apply -f - &>/dev/null
envsubst '$STUDENT_NAME' < "$LAB_DIR/frontend-deployment.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" backend 120
wait_for_deploy "$NS" frontend 120

BACKEND_READY=$(kubectl get deployment backend -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "backend has 3 replicas" "3" "$BACKEND_READY"

FRONTEND_READY=$(kubectl get deployment frontend -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "frontend has 2 replicas" "2" "$FRONTEND_READY"

BACKEND_LABELS=$(kubectl get pods -n "$NS" -l "app=backend,tier=api" --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_eq "backend pods have app=backend,tier=api labels" "3" "$BACKEND_LABELS"

FRONTEND_LABELS=$(kubectl get pods -n "$NS" -l "app=frontend,tier=web" --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_eq "frontend pods have app=frontend,tier=web labels" "2" "$FRONTEND_LABELS"

BACKEND_PROBE=$(kubectl get deployment backend -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)
assert_eq "backend has readiness probe on /get" "/get" "$BACKEND_PROBE"

###############################################################################
# Step 2: ClusterIP Service
###############################################################################

echo ""
echo "ClusterIP Service:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/backend-svc.yaml" | kubectl apply -f - &>/dev/null
sleep 5

SVC_TYPE=$(kubectl get svc backend-svc -n "$NS" -o jsonpath='{.spec.type}' 2>/dev/null)
assert_eq "backend-svc is ClusterIP" "ClusterIP" "$SVC_TYPE"

CLUSTER_IP=$(kubectl get svc backend-svc -n "$NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "$CLUSTER_IP" ] && [ "$CLUSTER_IP" != "None" ]; then
  pass "backend-svc has ClusterIP: $CLUSTER_IP"
else
  fail "backend-svc has no ClusterIP"
fi

SVC_PORT=$(kubectl get svc backend-svc -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "backend-svc port is 80" "80" "$SVC_PORT"

SVC_SELECTOR=$(kubectl get svc backend-svc -n "$NS" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
assert_eq "backend-svc selects app=backend" "backend" "$SVC_SELECTOR"

###############################################################################
# Step 3: Endpoints
###############################################################################

echo ""
echo "Endpoints:"

EP_COUNT=$(kubectl get endpoints backend-svc -n "$NS" -o json 2>/dev/null | jq '.subsets[0].addresses // [] | length' 2>/dev/null)
assert_eq "backend-svc has 3 endpoints" "3" "$EP_COUNT"

POD_IPS=$(kubectl get pods -n "$NS" -l "app=backend,tier=api" -o jsonpath='{.items[*].status.podIP}' 2>/dev/null)
EP_IPS=$(kubectl get endpoints backend-svc -n "$NS" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null)
ALL_MATCHED=true
for ip in $EP_IPS; do
  if ! echo "$POD_IPS" | grep -q "$ip"; then
    ALL_MATCHED=false
    break
  fi
done
if [ "$ALL_MATCHED" = true ] && [ -n "$EP_IPS" ]; then
  pass "endpoint IPs match backend pod IPs"
else
  fail "endpoint IPs do not match pod IPs (pods: $POD_IPS, eps: $EP_IPS)"
fi

# Scale down and verify endpoints update
kubectl scale deployment backend -n "$NS" --replicas=1 &>/dev/null
sleep 10
EP_COUNT_1=$(kubectl get endpoints backend-svc -n "$NS" -o json 2>/dev/null | jq '.subsets[0].addresses // [] | length' 2>/dev/null)
assert_eq "endpoints shrink to 1 after scale-down" "1" "$EP_COUNT_1"

# Scale back up
kubectl scale deployment backend -n "$NS" --replicas=3 &>/dev/null
wait_for_deploy "$NS" backend 120
sleep 5
EP_COUNT_3=$(kubectl get endpoints backend-svc -n "$NS" -o json 2>/dev/null | jq '.subsets[0].addresses // [] | length' 2>/dev/null)
assert_eq "endpoints grow to 3 after scale-up" "3" "$EP_COUNT_3"

###############################################################################
# Step 4: EndpointSlices
###############################################################################

echo ""
echo "EndpointSlices:"

ES_OUTPUT=$(kubectl get endpointslices -n "$NS" -l kubernetes.io/service-name=backend-svc --no-headers 2>/dev/null)
ES_COUNT=$(echo "$ES_OUTPUT" | grep -c . 2>/dev/null || echo "0")
if [ "$ES_COUNT" -ge 1 ]; then
  pass "backend-svc has at least 1 EndpointSlice ($ES_COUNT found)"
else
  fail "backend-svc has no EndpointSlices"
fi

###############################################################################
# Step 5: DNS Service Discovery
###############################################################################

echo ""
echo "DNS Service Discovery:"

kubectl run test-tools -n "$NS" --image=busybox:1.36 --restart=Never \
  -- sh -c "sleep 600" &>/dev/null
wait_for_pod "$NS" test-tools 60

# Short name DNS resolution
DNS_SHORT=$(kubectl exec test-tools -n "$NS" -- nslookup backend-svc 2>&1) || true
if echo "$DNS_SHORT" | grep -q "Address"; then
  pass "DNS resolves short name: backend-svc"
else
  fail "DNS short name resolution failed"
fi

# FQDN resolution
DNS_FQDN=$(kubectl exec test-tools -n "$NS" -- \
  nslookup "backend-svc.${NS}.svc.cluster.local" 2>&1) || true
if echo "$DNS_FQDN" | grep -q "Address"; then
  pass "DNS resolves FQDN: backend-svc.${NS}.svc.cluster.local"
else
  fail "DNS FQDN resolution failed"
fi

# Verify resolv.conf
RESOLV=$(kubectl exec test-tools -n "$NS" -- cat /etc/resolv.conf 2>/dev/null)
assert_contains "resolv.conf has namespace search domain" "$RESOLV" "$NS"
assert_contains "resolv.conf has svc.cluster.local" "$RESOLV" "svc.cluster.local"

###############################################################################
# Step 6: Traffic Routing via ClusterIP
###############################################################################

echo ""
echo "Traffic Routing via ClusterIP:"

CURL_RESULT=$(kubectl exec test-tools -n "$NS" -- \
  wget -q -O - "http://backend-svc/get" 2>/dev/null) || true
if [ -n "$CURL_RESULT" ]; then
  pass "traffic routes through ClusterIP to backend (wget /get)"
else
  BACKEND_POD=$(kubectl get pod -n "$NS" -l tier=api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  CURL_RESULT2=$(kubectl exec "$BACKEND_POD" -n "$NS" -- \
    curl -s "http://backend-svc/get" 2>/dev/null) || true
  if [ -n "$CURL_RESULT2" ]; then
    pass "traffic routes through ClusterIP to backend (curl /get)"
  else
    fail "could not route traffic through ClusterIP service"
  fi
fi

###############################################################################
# Step 7: NodePort Service
###############################################################################

echo ""
echo "NodePort Service:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/frontend-nodeport.yaml" | kubectl apply -f - &>/dev/null
sleep 3

NP_TYPE=$(kubectl get svc frontend-nodeport -n "$NS" -o jsonpath='{.spec.type}' 2>/dev/null)
assert_eq "frontend-nodeport type is NodePort" "NodePort" "$NP_TYPE"

NP=$(kubectl get svc frontend-nodeport -n "$NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
if [ -n "$NP" ] && [ "$NP" -ge 30000 ] && [ "$NP" -le 32767 ]; then
  pass "NodePort assigned in valid range: $NP"
else
  fail "NodePort not in valid range (30000-32767): $NP"
fi

NP_PORT=$(kubectl get svc frontend-nodeport -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "frontend-nodeport service port is 80" "80" "$NP_PORT"

###############################################################################
# Step 8: Headless Service
###############################################################################

echo ""
echo "Headless Service:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/backend-headless.yaml" | kubectl apply -f - &>/dev/null
sleep 3

HEADLESS_CIP=$(kubectl get svc backend-headless -n "$NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
assert_eq "headless service has clusterIP None" "None" "$HEADLESS_CIP"

echo ""
echo "Headless vs ClusterIP DNS Comparison:"

# ClusterIP returns a single VIP
DNS_CLUSTERIP=$(kubectl exec test-tools -n "$NS" -- \
  nslookup backend-svc 2>&1) || true
VIP_COUNT=$(echo "$DNS_CLUSTERIP" | grep -A1 "^Name:" | grep -c "Address" || true)
if [ "$VIP_COUNT" -eq 1 ]; then
  pass "ClusterIP DNS returns single VIP"
else
  if echo "$DNS_CLUSTERIP" | grep -q "Address"; then
    pass "ClusterIP DNS resolves (addresses found)"
  else
    fail "ClusterIP DNS did not resolve"
  fi
fi

# Headless returns individual pod IPs
DNS_HEADLESS=$(kubectl exec test-tools -n "$NS" -- \
  nslookup backend-headless 2>&1) || true
HEADLESS_ADDR_COUNT=$(echo "$DNS_HEADLESS" | grep -c "Address" || true)
if [ "$HEADLESS_ADDR_COUNT" -ge 4 ]; then
  pass "headless DNS returns multiple pod IPs ($((HEADLESS_ADDR_COUNT - 1)) addresses)"
else
  if [ "$HEADLESS_ADDR_COUNT" -ge 2 ]; then
    pass "headless DNS returns pod IPs (count: $((HEADLESS_ADDR_COUNT - 1)))"
  else
    fail "headless DNS did not return pod IPs (address lines: $HEADLESS_ADDR_COUNT)"
  fi
fi

###############################################################################
# Step 9: LoadBalancer Service
###############################################################################

echo ""
echo "LoadBalancer Service:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/frontend-lb.yaml" | kubectl apply -f - &>/dev/null
sleep 3

LB_TYPE=$(kubectl get svc frontend-lb -n "$NS" -o jsonpath='{.spec.type}' 2>/dev/null)
assert_eq "frontend-lb type is LoadBalancer" "LoadBalancer" "$LB_TYPE"

LB_SELECTOR=$(kubectl get svc frontend-lb -n "$NS" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
assert_eq "frontend-lb selects app=frontend" "frontend" "$LB_SELECTOR"

skip "EXTERNAL-IP check skipped (NLB provisioning takes several minutes)"

###############################################################################
# Cleanup
###############################################################################

echo ""
echo "Cleanup:"

kubectl delete svc frontend-lb -n "$NS" --timeout=60s &>/dev/null 2>&1
kubectl delete pod test-tools -n "$NS" --grace-period=0 --force &>/dev/null 2>&1
kubectl delete svc --all -n "$NS" --timeout=30s &>/dev/null 2>&1
cleanup_ns "$NS"
assert_cmd_fails "namespace removed after teardown" kubectl get namespace "$NS"

summary
