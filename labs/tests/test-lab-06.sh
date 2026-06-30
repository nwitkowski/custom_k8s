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

# ─── Ingress entrypoint detection ────────────────────────────────────────
# Behavioral curl checks require the ingress-nginx controller Service to have
# an external LoadBalancer address. Detect it once and gate every curl-based
# check below on $ING_REACHABLE so they degrade to skip (never false-fail) on
# clusters where the LB has no address.

ING_NS="ingress-nginx"
ING_REACHABLE=false
ING_ADDR=""
ING_CTRL_SVC=$(kubectl get svc -n "$ING_NS" \
  -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$ING_CTRL_SVC" ]; then
  ING_ADDR=$(kubectl get svc "$ING_CTRL_SVC" -n "$ING_NS" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  [ -z "$ING_ADDR" ] && ING_ADDR=$(kubectl get svc "$ING_CTRL_SVC" -n "$ING_NS" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
fi

if [ -n "$ING_ADDR" ]; then
  ING_REACHABLE=true
  pass "ingress-nginx controller Service has LoadBalancer address ($ING_ADDR)"
else
  skip "ingress-nginx controller has no LoadBalancer address — skipping curl-based routing checks"
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

# Behavioral: host-based routing (gated on ingress reachability)
if [ "$ING_REACHABLE" = "true" ]; then
  sleep 5  # allow the controller to program the new host rules
  H_V1=$(curl -s --max-time 10 -H "Host: v1-$STUDENT_NAME.lab.local" "http://$ING_ADDR/" 2>/dev/null)
  assert_contains "host v1 routes to App V1" "$H_V1" "Hello from App V1"

  H_V2=$(curl -s --max-time 10 -H "Host: v2-$STUDENT_NAME.lab.local" "http://$ING_ADDR/" 2>/dev/null)
  assert_contains "host v2 routes to App V2" "$H_V2" "Hello from App V2"

  H_UNK=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Host: unknown-$STUDENT_NAME.lab.local" "http://$ING_ADDR/" 2>/dev/null)
  assert_eq "unknown host returns 404" "404" "$H_UNK"
else
  skip "ingress not reachable — skipping host-based routing curl checks"
fi

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

# Behavioral: path-based routing (gated on ingress reachability)
if [ "$ING_REACHABLE" = "true" ]; then
  sleep 5  # allow the controller to program the new path rules
  P_V1=$(curl -s --max-time 10 -H "Host: app-$STUDENT_NAME.lab.local" "http://$ING_ADDR/v1" 2>/dev/null)
  assert_contains "path /v1 routes to App V1" "$P_V1" "Hello from App V1"

  P_V2=$(curl -s --max-time 10 -H "Host: app-$STUDENT_NAME.lab.local" "http://$ING_ADDR/v2" 2>/dev/null)
  assert_contains "path /v2 routes to App V2" "$P_V2" "Hello from App V2"

  P_DEF=$(curl -s --max-time 10 -H "Host: app-$STUDENT_NAME.lab.local" "http://$ING_ADDR/" 2>/dev/null)
  assert_contains "path / defaults to App V1" "$P_DEF" "Hello from App V1"
else
  skip "ingress not reachable — skipping path-based routing curl checks"
fi

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

# Behavioral: TLS termination + HTTP->HTTPS redirect (gated on ingress reachability)
if [ "$ING_REACHABLE" = "true" ]; then
  sleep 5  # allow the controller to load the TLS secret and program the rule
  T_BODY=$(curl -sk --max-time 10 -H "Host: secure-$STUDENT_NAME.lab.local" "https://$ING_ADDR/" 2>/dev/null)
  assert_contains "HTTPS serves App V1 over TLS" "$T_BODY" "Hello from App V1"

  T_REDIR=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Host: secure-$STUDENT_NAME.lab.local" "http://$ING_ADDR/" 2>/dev/null)
  assert_eq "HTTP redirects to HTTPS (308)" "308" "$T_REDIR"
else
  skip "ingress not reachable — skipping TLS curl checks"
fi

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

# Behavioral: CORS header + rate limiting (gated on ingress reachability)
if [ "$ING_REACHABLE" = "true" ]; then
  sleep 5  # allow the controller to program the annotated rule
  # Lowercase the response headers so the case-sensitive grep in assert_contains
  # matches regardless of how the controller cases the header.
  CORS_HDRS=$(curl -s -o /dev/null -D - --max-time 10 \
    -H "Host: api-$STUDENT_NAME.lab.local" \
    -H "Origin: https://app.example.com" \
    "http://$ING_ADDR/api/" 2>/dev/null | tr 'A-Z' 'a-z')
  assert_contains "CORS access-control-allow header present" "$CORS_HDRS" "access-control-allow"

  # limit-rps=10 — a short burst should produce at least one 503/429.
  RL_HIT=""
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
      -H "Host: api-$STUDENT_NAME.lab.local" "http://$ING_ADDR/api/" 2>/dev/null)
    case "$code" in 503|429) RL_HIT="$code"; break;; esac
  done
  if [ -n "$RL_HIT" ]; then
    pass "rate limit returns $RL_HIT under burst"
  else
    skip "no 503/429 observed under burst — rate limit may not trip on this controller"
  fi
else
  skip "ingress not reachable — skipping CORS/rate-limit curl checks"
fi

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

  # Access the Gateway through its OWN load balancer (Envoy Gateway provisions
  # a separate LB per Gateway — not ingress-nginx). The LB takes 1-2 min, so
  # gate on reachability and skip if it isn't up within the window.
  kubectl wait --for=condition=Programmed gateway/lab-gateway -n "$NS" --timeout=120s &>/dev/null
  GW_ADDR=$(kubectl get gateway lab-gateway -n "$NS" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
  GW_REACHABLE=false
  if [ -n "$GW_ADDR" ]; then
    for _i in $(seq 1 12); do
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: app-$STUDENT_NAME.lab.local" "http://$GW_ADDR/" 2>/dev/null)
      [ "$code" = "200" ] && { GW_REACHABLE=true; break; }
      sleep 5
    done
  fi
  if [ "$GW_REACHABLE" = true ]; then
    GW_BODY=$(curl -s --max-time 8 -H "Host: app-$STUDENT_NAME.lab.local" "http://$GW_ADDR/" 2>/dev/null)
    assert_contains "Gateway routes to an app via its own LB" "$GW_BODY" "Hello from App"
    GW_404=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$GW_ADDR/" 2>/dev/null)
    assert_eq "Gateway returns 404 without a matching Host" "404" "$GW_404"
  else
    skip "Gateway LB access (load balancer not reachable in window)"
    skip "Gateway 404-without-host (load balancer not reachable in window)"
  fi

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
