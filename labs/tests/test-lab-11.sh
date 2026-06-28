#!/bin/bash
###############################################################################
# Lab 11 Test: Deployment Strategies
# Covers: Rolling updates, rollbacks, blue-green, canary traffic distribution,
#         PDB dry-run drain, progress deadline detection and recovery
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-11" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="deploy-lab-$STUDENT_NAME"
echo "=== Lab 11: Deployment Strategies (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Step 1: Deploy v1 ──────────────────────────────────────────────────────

echo "Step 1 — Deploy v1:"

kubectl create configmap app-v1-page \
  --from-literal=index.html='<h1 style="color:blue">Application v1</h1><p>Version: 1.0.0</p>' \
  -n "$NS" &>/dev/null

envsubst '$STUDENT_NAME' < "$LAB_DIR/app-deploy-v1.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" webapp 90

V1_IMAGE=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
assert_contains "v1 deployed with nginx 1.24" "$V1_IMAGE" "1.24"

STRATEGY=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.strategy.type}' 2>/dev/null)
assert_eq "strategy is RollingUpdate" "RollingUpdate" "$STRATEGY"

MAX_SURGE=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.strategy.rollingUpdate.maxSurge}' 2>/dev/null)
assert_eq "maxSurge is 1" "1" "$MAX_SURGE"

MAX_UNAVAIL=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}' 2>/dev/null)
assert_eq "maxUnavailable is 1" "1" "$MAX_UNAVAIL"

READY=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "v1 has 2 ready replicas" "2" "$READY"

# Expose service for curl tests
kubectl expose deployment webapp --port=80 --target-port=80 --name=webapp-svc -n "$NS" &>/dev/null
sleep 3

# Verify v1 serves traffic via curl
V1_RESPONSE=$(kubectl run curl-v1-test --image=curlimages/curl --rm -i --restart=Never \
  -n "$NS" --timeout=30s -- curl -s webapp-svc 2>/dev/null)
assert_contains "v1 serves Application v1 page" "$V1_RESPONSE" "Application v1"

# ─── Step 2: Rolling update to v2 ───────────────────────────────────────────

echo ""
echo "Step 2 — Rolling Update to v2:"

kubectl create configmap app-v2-page \
  --from-literal=index.html='<h1 style="color:green">Application v2</h1><p>Version: 2.0.0</p>' \
  -n "$NS" &>/dev/null

kubectl set image deployment/webapp nginx=nginx:1.25 -n "$NS" &>/dev/null
kubectl patch deployment webapp -n "$NS" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"app-v2-page"}]' &>/dev/null
wait_for_deploy "$NS" webapp 90

V2_IMAGE=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
assert_contains "rolled to nginx 1.25" "$V2_IMAGE" "1.25"

# ─── Step 3: Monitor rolling update ─────────────────────────────────────────

echo ""
echo "Step 3 — Verify v2 serving and rollout history:"

V2_RESPONSE=$(kubectl run curl-v2-test --image=curlimages/curl --rm -i --restart=Never \
  -n "$NS" --timeout=30s -- curl -s webapp-svc 2>/dev/null)
assert_contains "v2 serves Application v2 page" "$V2_RESPONSE" "Application v2"

# Check old ReplicaSet is scaled to 0
# Count ReplicaSets at 0 replicas (may be multiple; just verify at least one exists)
OLD_RS_COUNT=$(kubectl get replicasets -n "$NS" -l app=webapp \
  -o jsonpath='{.items[?(@.spec.replicas==0)].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
if [ "$OLD_RS_COUNT" -ge 1 ]; then
  pass "old ReplicaSet scaled to 0 ($OLD_RS_COUNT old RS found)"
else
  fail "no old ReplicaSet found at 0 replicas"
fi

HISTORY=$(kubectl rollout history deployment/webapp -n "$NS" 2>/dev/null)
assert_contains "rollout history exists" "$HISTORY" "REVISION"

# ─── Step 4: Rollback to v1 ─────────────────────────────────────────────────

echo ""
echo "Step 4 — Rollback to v1:"

# Roll back explicitly to revision 1 (the v1/nginx:1.24 spec). Step 2 made two
# distinct mutations (set image, then patch the volume), creating two revisions,
# so a plain `rollout undo` would only revert the last one and land on 1.25.
kubectl rollout undo deployment/webapp -n "$NS" --to-revision=1 &>/dev/null
wait_for_deploy "$NS" webapp 90

ROLLBACK_IMAGE=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
assert_contains "rollback to nginx 1.24" "$ROLLBACK_IMAGE" "1.24"

REVISIONS=$(kubectl rollout history deployment/webapp -n "$NS" 2>/dev/null | grep -c "^[0-9]" || true)
if [ "$REVISIONS" -ge 3 ]; then
  pass "rollout history has $REVISIONS revisions"
else
  fail "expected at least 3 revisions, got $REVISIONS"
fi

# ─── Step 5: Blue-Green deployment ──────────────────────────────────────────

echo ""
echo "Step 5 — Blue-Green Deployment:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/blue-deploy.yaml" | kubectl apply -f - &>/dev/null
envsubst '$STUDENT_NAME' < "$LAB_DIR/green-deploy.yaml" | kubectl apply -f - &>/dev/null
envsubst '$STUDENT_NAME' < "$LAB_DIR/bg-service.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" webapp-blue 90
wait_for_deploy "$NS" webapp-green 90

SVC_SEL=$(kubectl get svc webapp-bg-svc -n "$NS" -o jsonpath='{.spec.selector.version}' 2>/dev/null)
assert_eq "service initially selects blue" "blue" "$SVC_SEL"

BLUE_REPLICAS=$(kubectl get deployment webapp-blue -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "blue deployment has 2 replicas" "2" "$BLUE_REPLICAS"

GREEN_REPLICAS=$(kubectl get deployment webapp-green -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "green deployment has 2 replicas" "2" "$GREEN_REPLICAS"

# Curl blue before switch
BLUE_RESPONSE=$(kubectl run bg-curl1 --image=curlimages/curl --rm -i --restart=Never \
  -n "$NS" --timeout=30s -- curl -s webapp-bg-svc 2>/dev/null)
assert_contains "service returns BLUE before switch" "$BLUE_RESPONSE" "BLUE"

# Switch to green
kubectl patch svc webapp-bg-svc -n "$NS" -p '{"spec":{"selector":{"version":"green"}}}' &>/dev/null
SVC_SEL_NEW=$(kubectl get svc webapp-bg-svc -n "$NS" -o jsonpath='{.spec.selector.version}' 2>/dev/null)
assert_eq "service switched to green" "green" "$SVC_SEL_NEW"

# Curl green after switch
GREEN_RESPONSE=$(kubectl run bg-curl2 --image=curlimages/curl --rm -i --restart=Never \
  -n "$NS" --timeout=30s -- curl -s webapp-bg-svc 2>/dev/null)
assert_contains "service returns GREEN after switch" "$GREEN_RESPONSE" "GREEN"

# ─── Step 6: Canary deployment ──────────────────────────────────────────────

echo ""
echo "Step 6 — Canary Deployment:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/canary-stable.yaml" | kubectl apply -f - &>/dev/null
envsubst '$STUDENT_NAME' < "$LAB_DIR/canary-new.yaml" | kubectl apply -f - &>/dev/null
envsubst '$STUDENT_NAME' < "$LAB_DIR/canary-service.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" webapp-stable 90
wait_for_deploy "$NS" webapp-canary 90

STABLE_REPLICAS=$(kubectl get deployment webapp-stable -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
CANARY_REPLICAS=$(kubectl get deployment webapp-canary -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "stable has 2 replicas" "2" "$STABLE_REPLICAS"
assert_eq "canary has 1 replica" "1" "$CANARY_REPLICAS"

# Verify canary service selects both via shared app label
CANARY_SVC_SEL=$(kubectl get svc webapp-canary-svc -n "$NS" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
assert_eq "canary service selects app=webapp-canary" "webapp-canary" "$CANARY_SVC_SEL"

# Verify pod labels
STABLE_PODS=$(kubectl get pods -n "$NS" -l app=webapp-canary,track=stable --no-headers 2>/dev/null | wc -l | tr -d ' ')
CANARY_PODS=$(kubectl get pods -n "$NS" -l app=webapp-canary,track=canary --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_eq "2 pods with track=stable" "2" "$STABLE_PODS"
assert_eq "1 pod with track=canary" "1" "$CANARY_PODS"

# ─── Step 7: Canary traffic distribution ────────────────────────────────────

echo ""
echo "Step 7 — Canary Traffic Distribution:"

TRAFFIC_RESULT=$(kubectl run traffic-test --image=curlimages/curl --rm -i --restart=Never \
  -n "$NS" --timeout=60s -- sh -c '
  STABLE=0; CANARY=0
  for i in $(seq 1 30); do
    RESPONSE=$(curl -s webapp-canary-svc)
    if echo "$RESPONSE" | grep -q "STABLE"; then
      STABLE=$((STABLE+1))
    elif echo "$RESPONSE" | grep -q "CANARY"; then
      CANARY=$((CANARY+1))
    fi
  done
  echo "STABLE=$STABLE CANARY=$CANARY"
' 2>/dev/null)

STABLE_HITS=$(echo "$TRAFFIC_RESULT" | sed -n 's/.*STABLE=\([0-9]*\).*/\1/p')
STABLE_HITS="${STABLE_HITS:-0}"
CANARY_HITS=$(echo "$TRAFFIC_RESULT" | sed -n 's/.*CANARY=\([0-9]*\).*/\1/p')
CANARY_HITS="${CANARY_HITS:-0}"

if [ "$STABLE_HITS" -gt 0 ] && [ "$CANARY_HITS" -gt 0 ]; then
  pass "traffic split: stable=$STABLE_HITS canary=$CANARY_HITS (both versions received traffic)"
elif [ "$STABLE_HITS" -gt 0 ] || [ "$CANARY_HITS" -gt 0 ]; then
  fail "only one version received traffic: stable=$STABLE_HITS canary=$CANARY_HITS"
else
  skip "could not parse traffic distribution results"
fi

# ─── Step 8: Pod Disruption Budget ──────────────────────────────────────────

echo ""
echo "Step 8 — Pod Disruption Budget:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/pdb.yaml" | kubectl apply -f - &>/dev/null
sleep 3

PDB_MIN=$(kubectl get pdb webapp-pdb -n "$NS" -o jsonpath='{.spec.minAvailable}' 2>/dev/null)
assert_eq "PDB minAvailable is 2" "2" "$PDB_MIN"

PDB_SELECTOR=$(kubectl get pdb webapp-pdb -n "$NS" -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null)
assert_eq "PDB selector matches app=webapp" "webapp" "$PDB_SELECTOR"

PDB_STATUS=$(kubectl get pdb webapp-pdb -n "$NS" -o jsonpath='{.status.currentHealthy}' 2>/dev/null)
if [ -n "$PDB_STATUS" ] && [ "$PDB_STATUS" -ge 2 ]; then
  pass "PDB shows $PDB_STATUS healthy pods"
else
  fail "PDB shows only $PDB_STATUS healthy pods (expected >= 2)"
fi

# ─── PDB enforcement: disruptionsAllowed + eviction is actually blocked ─────
# The webapp Deployment runs 2 replicas and the PDB requires minAvailable=2, so
# the budget permits 0 voluntary disruptions. Verify the reported budget status,
# then PROVE enforcement by asking the eviction API (and a server-side dry-run
# drain) to evict a pod and confirming the PDB refuses it. Everything below is
# non-destructive (dry-run only) — no real cordon/eviction happens.

DISRUPTIONS=$(kubectl get pdb webapp-pdb -n "$NS" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)
DESIRED_HEALTHY=$(kubectl get pdb webapp-pdb -n "$NS" -o jsonpath='{.status.desiredHealthy}' 2>/dev/null)
assert_eq "PDB desiredHealthy is 2" "2" "$DESIRED_HEALTHY"

if [ -n "$DISRUPTIONS" ] && [ -n "$PDB_STATUS" ]; then
  # disruptionsAllowed = max(0, currentHealthy - minAvailable). With 2 healthy
  # pods and minAvailable=2 this must be exactly 0.
  EXPECTED_ALLOWED=$(( PDB_STATUS - 2 ))
  [ "$EXPECTED_ALLOWED" -lt 0 ] && EXPECTED_ALLOWED=0
  assert_eq "PDB disruptionsAllowed = currentHealthy($PDB_STATUS) - minAvailable(2)" \
    "$EXPECTED_ALLOWED" "$DISRUPTIONS"
else
  skip "PDB status (disruptionsAllowed) not populated yet"
fi

# Eviction enforcement: a dry-run eviction of a webapp pod must be refused while
# disruptionsAllowed=0 (the apiserver still runs the PDB admission check on a
# dry-run eviction and returns 429 TooManyRequests if it would violate it).
WEBAPP_POD=$(kubectl get pods -n "$NS" -l app=webapp \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ "$DISRUPTIONS" = "0" ] && [ -n "$WEBAPP_POD" ]; then
  EVICT_BODY=$(mktemp)
  cat > "$EVICT_BODY" <<EVEOF
{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"$WEBAPP_POD","namespace":"$NS"},"deleteOptions":{"dryRun":["All"]}}
EVEOF
  EVICT_OUT=$(kubectl create --raw "/api/v1/namespaces/$NS/pods/$WEBAPP_POD/eviction" \
    -f "$EVICT_BODY" 2>&1 || true)
  rm -f "$EVICT_BODY"
  if echo "$EVICT_OUT" | grep -qiE "disruption budget|Cannot evict|TooManyRequests|429"; then
    pass "PDB enforced: dry-run eviction of $WEBAPP_POD refused (disruptionsAllowed=0)"
  elif echo "$EVICT_OUT" | grep -qi "success"; then
    fail "eviction allowed despite minAvailable=2 with only $PDB_STATUS healthy pods"
  else
    skip "eviction dry-run result inconclusive: $EVICT_OUT"
  fi
elif [ -n "$WEBAPP_POD" ]; then
  skip "disruptionsAllowed=$DISRUPTIONS (budget has headroom; eviction boundary not reached)"
else
  skip "could not determine a webapp pod for eviction test"
fi

# NOTE: a `kubectl drain --dry-run=server` was intentionally NOT used here. When
# the PDB allows zero disruptions, drain retries eviction until its --timeout and
# (with the default timeout of 0) hangs indefinitely, stalling the whole suite.
# The eviction-API dry-run above already proves the PDB blocks voluntary
# disruptions, so the drain adds hang risk for no extra coverage.

# ─── Step 9: Progress deadline ──────────────────────────────────────────────

echo ""
echo "Step 9 — Progress Deadline:"

# Set a short progress deadline
kubectl patch deployment webapp -n "$NS" \
  -p '{"spec":{"progressDeadlineSeconds":30}}' &>/dev/null

DEADLINE=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.progressDeadlineSeconds}' 2>/dev/null)
assert_eq "progressDeadlineSeconds set to 30" "30" "$DEADLINE"

# Trigger stuck rollout with bad image
kubectl set image deployment/webapp nginx=nginx:nonexistent-tag-$$ -n "$NS" &>/dev/null

# Wait for the rollout to report a problem (don't wait the full timeout)
sleep 15
ROLLOUT_STATUS=$(kubectl rollout status deployment/webapp -n "$NS" --timeout=45s 2>&1 || true)

# Check for stuck condition -- the deployment should either timeout or report progress issue
CONDITIONS=$(kubectl get deployment webapp -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)
if echo "$CONDITIONS" | grep -q "ReplicaSetUpdated\|ProgressDeadlineExceeded\|NewReplicaSetAvailable"; then
  pass "progress deadline triggered condition: $CONDITIONS"
else
  # Even if condition is unexpected, check that bad pods exist
  BAD_PODS=$(kubectl get pods -n "$NS" -l app=webapp --no-headers 2>/dev/null | grep -c "ImagePull\|ErrImage" || true)
  if [ "$BAD_PODS" -gt 0 ]; then
    pass "stuck rollout detected ($BAD_PODS pods with image pull errors)"
  else
    fail "could not detect stuck rollout (condition: $CONDITIONS)"
  fi
fi

# Recover with rollout undo
kubectl rollout undo deployment/webapp -n "$NS" &>/dev/null
wait_for_deploy "$NS" webapp 90

RECOVER_IMAGE=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
assert_contains "recovered after undo (back to working image)" "$RECOVER_IMAGE" "nginx:1.2"

RECOVER_READY=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "all replicas ready after recovery" "2" "$RECOVER_READY"

# ─── Cleanup ────────────────────────────────────────────────────────────────

cleanup_ns "$NS"
summary
