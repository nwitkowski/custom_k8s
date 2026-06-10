#!/bin/bash
###############################################################################
# Lab 6 Test: Ingress Routing, TLS, Gateway API & Egress Policy
# Covers: App deployment, host-based ingress, path-based ingress, TLS ingress,
#         ingress annotations, Gateway API, egress NetworkPolicy
#         — resource verification only (no behavioral tests)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-06" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab06-$STUDENT_NAME"
echo "=== Lab 6: Ingress Routing & TLS (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Step 1: Deploy apps ──────────────────────────────────────────────────

echo "Step 1: Deploy Sample Applications"

envsubst '$STUDENT_NAME' < "$LAB_DIR/app-v1.yaml" | kubectl apply -f - &>/dev/null
envsubst '$STUDENT_NAME' < "$LAB_DIR/app-v2.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" app-v1 90
wait_for_deploy "$NS" app-v2 90

V1_READY=$(kubectl get deployment app-v1 -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "app-v1 has 2 ready replicas" "2" "$V1_READY"

V2_READY=$(kubectl get deployment app-v2 -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "app-v2 has 2 ready replicas" "2" "$V2_READY"

assert_cmd "app-v1-svc exists" kubectl get svc app-v1-svc -n "$NS"
assert_cmd "app-v2-svc exists" kubectl get svc app-v2-svc -n "$NS"

V1_PORT=$(kubectl get svc app-v1-svc -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "app-v1-svc port is 80" "80" "$V1_PORT"

V2_PORT=$(kubectl get svc app-v2-svc -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "app-v2-svc port is 80" "80" "$V2_PORT"

# ─── Step 2: IngressClass verification ───────────────────────────────────

echo ""
echo "Step 2: IngressClass"

if kubectl get ingressclass nginx &>/dev/null; then
  pass "IngressClass nginx exists"
else
  skip "IngressClass nginx not found — skipping remaining ingress tests"
  cleanup_ns "$NS"
  summary
  exit 0
fi

# ─── Step 3: Host-based Ingress ──────────────────────────────────────────

echo ""
echo "Step 3: Host-Based Ingress"

envsubst '$STUDENT_NAME' < "$LAB_DIR/ingress-host.yaml" | kubectl apply -f - &>/dev/null
sleep 3

assert_cmd "host-based ingress created" kubectl get ingress app-ingress-host -n "$NS"

ING_RULES=$(kubectl get ingress app-ingress-host -n "$NS" -o json 2>/dev/null)
RULE_COUNT=$(echo "$ING_RULES" | jq '.spec.rules | length' 2>/dev/null || echo "0")
assert_eq "host ingress has 2 rules" "2" "$RULE_COUNT"

HOST1=$(echo "$ING_RULES" | jq -r '.spec.rules[0].host' 2>/dev/null)
assert_contains "first host contains v1-" "$HOST1" "v1-"

HOST2=$(echo "$ING_RULES" | jq -r '.spec.rules[1].host' 2>/dev/null)
assert_contains "second host contains v2-" "$HOST2" "v2-"

# ─── Step 4: Path-based Ingress ──────────────────────────────────────────

echo ""
echo "Step 4: Path-Based Ingress"

envsubst '$STUDENT_NAME' < "$LAB_DIR/ingress-path.yaml" | kubectl apply -f - &>/dev/null
sleep 3

assert_cmd "path-based ingress created" kubectl get ingress app-ingress-path -n "$NS"

PATH_V1=$(kubectl get ingress app-ingress-path -n "$NS" \
  -o jsonpath='{.spec.rules[0].http.paths[0].path}' 2>/dev/null)
assert_eq "path ingress has /v1 path" "/v1" "$PATH_V1"

PATH_V2=$(kubectl get ingress app-ingress-path -n "$NS" \
  -o jsonpath='{.spec.rules[0].http.paths[1].path}' 2>/dev/null)
assert_eq "path ingress has /v2 path" "/v2" "$PATH_V2"

PATH_DEFAULT=$(kubectl get ingress app-ingress-path -n "$NS" \
  -o jsonpath='{.spec.rules[0].http.paths[2].path}' 2>/dev/null)
assert_eq "path ingress has / default path" "/" "$PATH_DEFAULT"

# ─── Step 5: TLS Ingress ────────────────────────────────────────────────

echo ""
echo "Step 5: TLS Termination"

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/tls-ingress-$$.key -out /tmp/tls-ingress-$$.crt \
  -subj "/CN=*.lab.local/O=Lab" &>/dev/null

kubectl create secret tls lab-tls-secret \
  --cert=/tmp/tls-ingress-$$.crt --key=/tmp/tls-ingress-$$.key \
  -n "$NS" &>/dev/null

assert_cmd "TLS secret lab-tls-secret created" kubectl get secret lab-tls-secret -n "$NS"

envsubst '$STUDENT_NAME' < "$LAB_DIR/ingress-tls.yaml" | kubectl apply -f - &>/dev/null
sleep 3

assert_cmd "TLS ingress created" kubectl get ingress app-ingress-tls -n "$NS"

TLS_SPEC=$(kubectl get ingress app-ingress-tls -n "$NS" -o jsonpath='{.spec.tls}' 2>/dev/null)
assert_contains "TLS ingress has tls config" "$TLS_SPEC" "lab-tls-secret"

SSL_REDIR=$(kubectl get ingress app-ingress-tls -n "$NS" \
  -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/ssl-redirect}' 2>/dev/null)
assert_eq "TLS ingress has ssl-redirect=true" "true" "$SSL_REDIR"

rm -f /tmp/tls-ingress-$$.key /tmp/tls-ingress-$$.crt

# ─── Step 6: Ingress Annotations ────────────────────────────────────────

echo ""
echo "Step 6: Ingress Annotations"

envsubst '$STUDENT_NAME' < "$LAB_DIR/ingress-annotations.yaml" | kubectl apply -f - &>/dev/null
sleep 3

assert_cmd "annotated ingress created" kubectl get ingress app-ingress-advanced -n "$NS"

ANN_REWRITE=$(kubectl get ingress app-ingress-advanced -n "$NS" \
  -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/rewrite-target}' 2>/dev/null)
assert_eq "rewrite-target annotation = /\$2" '/$2' "$ANN_REWRITE"

ANN_RPS=$(kubectl get ingress app-ingress-advanced -n "$NS" \
  -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/limit-rps}' 2>/dev/null)
assert_eq "rate limit annotation = 10" "10" "$ANN_RPS"

ANN_CORS=$(kubectl get ingress app-ingress-advanced -n "$NS" \
  -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/enable-cors}' 2>/dev/null)
assert_eq "CORS enabled annotation = true" "true" "$ANN_CORS"

ANN_ORIGIN=$(kubectl get ingress app-ingress-advanced -n "$NS" \
  -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/cors-allow-origin}' 2>/dev/null)
assert_eq "CORS origin = https://app.example.com" "https://app.example.com" "$ANN_ORIGIN"

# ─── Step 7: Gateway API (conditional) ─────────────────────────────────

echo ""
echo "Step 7: Gateway API"

if kubectl get crd gatewayclasses.gateway.networking.k8s.io &>/dev/null; then
  envsubst '$STUDENT_NAME' < "$LAB_DIR/gateway.yaml" | kubectl apply -f - &>/dev/null
  sleep 3

  assert_cmd "GatewayClass created" kubectl get gatewayclass "lab-gateway-class-$STUDENT_NAME"

  envsubst '$STUDENT_NAME' < "$LAB_DIR/httproute.yaml" | kubectl apply -f - &>/dev/null
  sleep 3

  assert_cmd "HTTPRoute created" kubectl get httproute app-route -n "$NS"

  W_V1=$(kubectl get httproute app-route -n "$NS" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].weight}' 2>/dev/null)
  assert_eq "HTTPRoute v1 weight is 80" "80" "$W_V1"

  W_V2=$(kubectl get httproute app-route -n "$NS" \
    -o jsonpath='{.spec.rules[0].backendRefs[1].weight}' 2>/dev/null)
  assert_eq "HTTPRoute v2 weight is 20" "20" "$W_V2"

  # Clean up: delete the Gateway first so Envoy Gateway releases the
  # gateway-exists finalizer on the GatewayClass, otherwise the GatewayClass
  # delete blocks indefinitely. Timeouts guard against a stuck finalizer.
  kubectl delete httproute app-route -n "$NS" --ignore-not-found --timeout=60s &>/dev/null
  kubectl delete gateway lab-gateway -n "$NS" --ignore-not-found --timeout=60s &>/dev/null
  kubectl delete gatewayclass "lab-gateway-class-$STUDENT_NAME" --ignore-not-found --timeout=60s &>/dev/null
else
  skip "Gateway API CRD not installed — skipping Gateway tests"
fi

# ─── Step 8: Egress NetworkPolicy ──────────────────────────────────────

echo ""
echo "Step 8: Egress NetworkPolicy"

envsubst '$STUDENT_NAME' < "$LAB_DIR/egress-policy.yaml" | kubectl apply -f - &>/dev/null
sleep 2

assert_cmd "egress policy exists" kubectl get networkpolicy restrict-egress -n "$NS"

EGRESS_SEL=$(kubectl get networkpolicy restrict-egress -n "$NS" \
  -o jsonpath='{.spec.podSelector.matchLabels.run}' 2>/dev/null)
assert_eq "egress policy selects run=egress-test" "egress-test" "$EGRESS_SEL"

EGRESS_TYPE=$(kubectl get networkpolicy restrict-egress -n "$NS" \
  -o jsonpath='{.spec.policyTypes[0]}' 2>/dev/null)
assert_eq "egress policy has Egress policyType" "Egress" "$EGRESS_TYPE"

DNS_PORT=$(kubectl get networkpolicy restrict-egress -n "$NS" \
  -o jsonpath='{.spec.egress[0].ports[0].port}' 2>/dev/null)
assert_eq "egress allows DNS on port 53" "53" "$DNS_PORT"

# ─── Cleanup ──────────────────────────────────────────────────────────────

cleanup_ns "$NS"
summary
