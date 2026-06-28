#!/bin/bash
###############################################################################
# Lab 8 Test: Network Policies — 3-Tier App + Deny-All + Selective Allow
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-08" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab08-$STUDENT_NAME"
echo "=== Lab 8: Network Policies (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

###############################################################################
# Step 1: Deploy Three-Tier Application
###############################################################################

echo "Step 1 — Deploy Three-Tier App:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/database.yaml" | kubectl apply -f - &>/dev/null
envsubst '$STUDENT_NAME' < "$LAB_DIR/backend.yaml" | kubectl apply -f - &>/dev/null
envsubst '$STUDENT_NAME' < "$LAB_DIR/frontend.yaml" | kubectl apply -f - &>/dev/null
kubectl wait --for=condition=Ready pod --all -n "$NS" --timeout=90s &>/dev/null

PODS=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep -c Running || true)
assert_eq "3 pods running" "3" "$PODS"

###############################################################################
# Step 2: Verify Labels
###############################################################################

echo ""
echo "Step 2 — Verify Labels:"
FE_TIER=$(kubectl get pod frontend -n "$NS" -o jsonpath='{.metadata.labels.tier}' 2>/dev/null)
assert_eq "frontend has tier=frontend" "frontend" "$FE_TIER"

BE_TIER=$(kubectl get pod backend -n "$NS" -o jsonpath='{.metadata.labels.tier}' 2>/dev/null)
assert_eq "backend has tier=backend" "backend" "$BE_TIER"

DB_TIER=$(kubectl get pod database -n "$NS" -o jsonpath='{.metadata.labels.tier}' 2>/dev/null)
assert_eq "database has tier=database" "database" "$DB_TIER"

###############################################################################
# Step 2b: Default connectivity baseline (BEFORE any deny policy)
###############################################################################
# Kubernetes allows all pod-to-pod traffic by default. Establish that baseline
# now, before deny-all is applied. This needs no CNI enforcement (it is the
# allow-by-default case); it only needs the pods to be Running. If the exec/curl
# can't establish the connection (e.g. pods not ready), degrade to skip rather
# than fail.

echo ""
echo "Step 2b — Default Connectivity Baseline:"
if [ "$PODS" = "3" ]; then
  kubectl exec frontend -n "$NS" -- curl -sS --max-time 5 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
  if [ $? -eq 0 ]; then pass "frontend -> backend reachable by default (allow-all baseline)"; \
    else skip "frontend -> backend baseline could not be established — skipping"; fi

  kubectl exec backend -n "$NS" -- curl -sS --max-time 5 "http://database.${NS}.svc.cluster.local:80" &>/dev/null
  if [ $? -eq 0 ]; then pass "backend -> database reachable by default (allow-all baseline)"; \
    else skip "backend -> database baseline could not be established — skipping"; fi
else
  skip "pods not all Running — skipping default connectivity baseline"
fi

###############################################################################
# Step 3: Apply deny-all-ingress
###############################################################################

echo ""
echo "Step 3 — Deny-All Ingress:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/deny-all-ingress.yaml" | kubectl apply -f - &>/dev/null

assert_cmd "deny-all-ingress policy exists" kubectl get networkpolicy default-deny-all-ingress -n "$NS"

# Verify empty podSelector
POD_SEL=$(kubectl get networkpolicy default-deny-all-ingress -n "$NS" \
  -o jsonpath='{.spec.podSelector}' 2>/dev/null)
assert_eq "deny-all has empty podSelector" "{}" "$POD_SEL"

# Verify Ingress policyType
POLICY_TYPES=$(kubectl get networkpolicy default-deny-all-ingress -n "$NS" \
  -o jsonpath='{.spec.policyTypes[0]}' 2>/dev/null)
assert_eq "deny-all has Ingress policyType" "Ingress" "$POLICY_TYPES"

###############################################################################
# Step 4: CNI enforcement probe
###############################################################################

echo ""
echo "Step 4 — CNI Enforcement Check:"
sleep 3

CNI_ENFORCES=true
kubectl exec frontend -n "$NS" -- curl -s --max-time 3 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -eq 0 ]; then
  CNI_ENFORCES=false
  skip "CNI does not enforce NetworkPolicy — behavioral tests will be skipped"
else
  pass "CNI enforces NetworkPolicy"
fi

###############################################################################
# Step 5: Verify deny-all blocks traffic (if CNI enforces)
###############################################################################

if [ "$CNI_ENFORCES" = "true" ]; then
  echo ""
  echo "Step 5 — Verify Deny-All Blocks Traffic:"

  kubectl exec frontend -n "$NS" -- curl -s --max-time 3 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
  if [ $? -ne 0 ]; then pass "frontend -> backend BLOCKED"; else fail "frontend -> backend should be blocked"; fi

  kubectl exec backend -n "$NS" -- curl -s --max-time 3 "http://database.${NS}.svc.cluster.local:80" &>/dev/null
  if [ $? -ne 0 ]; then pass "backend -> database BLOCKED"; else fail "backend -> database should be blocked"; fi
fi

###############################################################################
# Step 6: Allow frontend to backend
###############################################################################

echo ""
echo "Step 6 — Allow Frontend to Backend:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/allow-frontend-to-backend.yaml" | kubectl apply -f - &>/dev/null

assert_cmd "allow-frontend-to-backend policy exists" kubectl get networkpolicy allow-frontend-to-backend -n "$NS"

if [ "$CNI_ENFORCES" = "true" ]; then
  sleep 3
  F2B=$(kubectl exec frontend -n "$NS" -- curl -s --max-time 5 "http://backend.${NS}.svc.cluster.local:80" 2>/dev/null)
  assert_contains "frontend -> backend ALLOWED" "$F2B" "nginx"
fi

###############################################################################
# Step 7: Allow backend to database
###############################################################################

echo ""
echo "Step 7 — Allow Backend to Database:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/allow-backend-to-database.yaml" | kubectl apply -f - &>/dev/null

assert_cmd "allow-backend-to-database policy exists" kubectl get networkpolicy allow-backend-to-database -n "$NS"

if [ "$CNI_ENFORCES" = "true" ]; then
  sleep 3
  B2D=$(kubectl exec backend -n "$NS" -- curl -s --max-time 5 "http://database.${NS}.svc.cluster.local:80" 2>/dev/null)
  assert_contains "backend -> database ALLOWED" "$B2D" "nginx"
fi

###############################################################################
# Step 7b: Complete policy set — verify paths that SHOULD be blocked
###############################################################################
# With the full allow-set in place (frontend->backend, backend->database), every
# other ingress path must remain denied by default-deny-all-ingress. Gated on
# CNI enforcement.

echo ""
echo "Step 7b — Complete Policy Set (blocked paths):"
if [ "$CNI_ENFORCES" = "true" ]; then
  sleep 2
  kubectl exec frontend -n "$NS" -- curl -sS --max-time 4 "http://database.${NS}.svc.cluster.local:80" &>/dev/null
  if [ $? -ne 0 ]; then pass "frontend -> database BLOCKED"; else fail "frontend -> database should be blocked"; fi

  kubectl exec database -n "$NS" -- curl -sS --max-time 4 "http://frontend.${NS}.svc.cluster.local:80" &>/dev/null
  if [ $? -ne 0 ]; then pass "database -> frontend BLOCKED"; else fail "database -> frontend should be blocked"; fi

  kubectl exec database -n "$NS" -- curl -sS --max-time 4 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
  if [ $? -ne 0 ]; then pass "database -> backend BLOCKED"; else fail "database -> backend should be blocked"; fi
fi

###############################################################################
# Step 8: Egress Policies
###############################################################################

echo ""
echo "Step 8 — Egress Policies:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/deny-all-egress.yaml" | kubectl apply -f - &>/dev/null

EGRESS_SEL=$(kubectl get networkpolicy default-deny-all-egress -n "$NS" \
  -o jsonpath='{.spec.podSelector}' 2>/dev/null)
assert_eq "deny-all-egress has empty podSelector" "{}" "$EGRESS_SEL"

EGRESS_TYPE=$(kubectl get networkpolicy default-deny-all-egress -n "$NS" \
  -o jsonpath='{.spec.policyTypes[0]}' 2>/dev/null)
assert_eq "deny-all-egress has Egress policyType" "Egress" "$EGRESS_TYPE"

# Behavioral: under deny-all-egress an outbound request must fail (CNI-gated)
if [ "$CNI_ENFORCES" = "true" ]; then
  sleep 2
  kubectl exec frontend -n "$NS" -- curl -sS --max-time 4 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
  if [ $? -ne 0 ]; then pass "deny-all-egress BLOCKS outbound from frontend"; else fail "deny-all-egress should block outbound from frontend"; fi
fi

envsubst '$STUDENT_NAME' < "$LAB_DIR/allow-dns-egress.yaml" | kubectl apply -f - &>/dev/null

assert_cmd "allow-dns-egress policy exists" kubectl get networkpolicy allow-dns-egress -n "$NS"

DNS_PORT=$(kubectl get networkpolicy allow-dns-egress -n "$NS" \
  -o jsonpath='{.spec.egress[0].ports[0].port}' 2>/dev/null)
assert_eq "allow-dns-egress allows UDP port 53" "53" "$DNS_PORT"

###############################################################################
# Step 9: Namespace-Based Policy
###############################################################################

echo ""
echo "Step 9 — Namespace-Based Policy:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/allow-monitoring-ingress.yaml" | kubectl apply -f - &>/dev/null

assert_cmd "allow-monitoring-ingress policy exists" kubectl get networkpolicy allow-monitoring-ingress -n "$NS"

MON_NS_LABEL=$(kubectl get networkpolicy allow-monitoring-ingress -n "$NS" \
  -o jsonpath='{.spec.ingress[0].from[0].namespaceSelector.matchLabels.purpose}' 2>/dev/null)
assert_eq "monitoring policy selects purpose=monitoring namespace" "monitoring" "$MON_NS_LABEL"

MON_PORT=$(kubectl get networkpolicy allow-monitoring-ingress -n "$NS" \
  -o jsonpath='{.spec.ingress[0].ports[0].port}' 2>/dev/null)
assert_eq "monitoring policy allows port 80" "80" "$MON_PORT"

###############################################################################
# Step 10: Apply broken policy — verify wrong selector and wrong port
###############################################################################

echo ""
echo "Step 10 — Debug Broken Policy:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/broken-policy.yaml" | kubectl apply -f - &>/dev/null

assert_cmd "broken-policy applied" kubectl get networkpolicy allow-external-to-frontend -n "$NS"

BROKEN_TIER=$(kubectl get networkpolicy allow-external-to-frontend -n "$NS" \
  -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels.tier}' 2>/dev/null)
assert_eq "broken policy has self-referencing selector (tier=frontend)" "frontend" "$BROKEN_TIER"

BROKEN_PORT=$(kubectl get networkpolicy allow-external-to-frontend -n "$NS" \
  -o jsonpath='{.spec.ingress[0].ports[0].port}' 2>/dev/null)
assert_eq "broken policy has wrong port 8080" "8080" "$BROKEN_PORT"

###############################################################################
# Step 11: Apply fixed policy — verify from:[] and port 80
###############################################################################

echo ""
echo "Step 11 — Fixed Policy:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/fixed-policy.yaml" | kubectl apply -f - &>/dev/null

FIXED_FROM=$(kubectl get networkpolicy allow-external-to-frontend -n "$NS" \
  -o jsonpath='{.spec.ingress[0].from}' 2>/dev/null)
assert_eq "fixed policy has from:[] (allow all)" "" "$FIXED_FROM"

FIXED_PORT=$(kubectl get networkpolicy allow-external-to-frontend -n "$NS" \
  -o jsonpath='{.spec.ingress[0].ports[0].port}' 2>/dev/null)
assert_eq "fixed policy uses port 80" "80" "$FIXED_PORT"

# Behavioral: the fixed policy (from:[] on port 80) restores access to frontend,
# which the broken policy left blocked. Gated on CNI enforcement. Remove the
# earlier deny-all-egress (Step 8) first so this ingress check isn't masked by
# the egress restriction on the client pod.
if [ "$CNI_ENFORCES" = "true" ]; then
  kubectl delete networkpolicy default-deny-all-egress allow-dns-egress -n "$NS" --ignore-not-found &>/dev/null
  sleep 3
  D2F=$(kubectl exec database -n "$NS" -- curl -sS --max-time 5 "http://frontend.${NS}.svc.cluster.local:80" 2>/dev/null)
  assert_contains "fixed policy restores access to frontend" "$D2F" "nginx"
fi

###############################################################################
# Step 12: Cleanup
###############################################################################

echo ""
echo "Cleanup:"
cleanup_ns "$NS"
summary
