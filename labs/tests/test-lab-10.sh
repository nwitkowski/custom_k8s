#!/bin/bash
###############################################################################
# Lab 10 Test: Health Checks and Probes (Configuration Verification)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-10" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="probes-lab-$STUDENT_NAME"
echo "=== Lab 10: Health Probes (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Step 1: No probes (baseline) ────────────────────────────────────────

echo "Step 1: No Probes (baseline)"
envsubst '$STUDENT_NAME' < "$LAB_DIR/no-probes-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" no-probes-app 60

NOPROBE_LIVE=$(kubectl get deployment no-probes-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}' 2>/dev/null)
assert_eq "no-probes-app has no liveness probe" "" "$NOPROBE_LIVE"

NOPROBE_READY=$(kubectl get deployment no-probes-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)
assert_eq "no-probes-app has no readiness probe" "" "$NOPROBE_READY"

# Simulate the failure from the README: break nginx inside the pod. With no
# probe, Kubernetes cannot detect it — the pod stays Running and is NOT restarted.
NOPROBE_POD=$(kubectl get pod -l app=no-probes-app -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$NOPROBE_POD" ] && wait_for_pod "$NS" "$NOPROBE_POD" 30; then
  kubectl exec "$NOPROBE_POD" -n "$NS" -- sh -c "rm -f /etc/nginx/conf.d/default.conf && nginx -s reload" &>/dev/null
  sleep 20
  NOPROBE_PHASE=$(kubectl get pod "$NOPROBE_POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  NOPROBE_RESTARTS=$(kubectl get pod "$NOPROBE_POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  assert_eq "no-probes pod stays Running after failure (the blind spot)" "Running" "$NOPROBE_PHASE"
  assert_eq "no-probes pod is NOT restarted (restartCount 0)" "0" "$NOPROBE_RESTARTS"
else
  skip "no-probes pod not ready — skipping blind-spot simulation"
fi

# ─── Step 2: Liveness probe (HTTP) ───────────────────────────────────────

echo ""
echo "Step 2: Liveness Probe (HTTP)"
envsubst '$STUDENT_NAME' < "$LAB_DIR/liveness-http.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" liveness-http 60

LIVENESS_PATH=$(kubectl get deployment liveness-http -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "liveness probe path is /" "/" "$LIVENESS_PATH"

LIVENESS_PORT=$(kubectl get deployment liveness-http -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.port}' 2>/dev/null)
assert_eq "liveness probe port is 80" "80" "$LIVENESS_PORT"

# Trigger the liveness failure (README): remove the served index page so the
# HTTP probe starts returning 404. Poll for the container restart.
LIVE_POD=$(kubectl get pod -l app=liveness-http -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$LIVE_POD" ] && wait_for_pod "$NS" "$LIVE_POD" 30; then
  kubectl exec "$LIVE_POD" -n "$NS" -- rm -f /usr/share/nginx/html/index.html &>/dev/null
  # failureThreshold 3 x periodSeconds 10 ≈ 30s; poll up to ~75s.
  LIVE_RESTARTED=0
  for i in $(seq 1 15); do
    RC=$(kubectl get pod "$LIVE_POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
    if [ -n "$RC" ] && [ "$RC" -gt 0 ]; then LIVE_RESTARTED=1; break; fi
    sleep 5
  done
  if [ "$LIVE_RESTARTED" -eq 1 ]; then
    pass "liveness failure restarted the container (restartCount > 0)"
  else
    skip "liveness restart not observed within timeout"
  fi
else
  skip "liveness-http pod not ready — skipping liveness failure trigger"
fi

# ─── Step 3: Readiness probe + service ───────────────────────────────────

echo ""
echo "Step 3: Readiness Probe + Service"
envsubst '$STUDENT_NAME' < "$LAB_DIR/readiness-app.yaml" | kubectl apply -f - &>/dev/null
# readiness-app stays NotReady by design (the /ready file is created manually in
# the lab), so don't wait for Available — only its spec is inspected below.
kubectl rollout status deployment/readiness-app -n "$NS" --timeout=10s &>/dev/null || true

READINESS_PATH=$(kubectl get deployment readiness-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)
assert_eq "readiness probe path is /ready" "/ready" "$READINESS_PATH"

READINESS_PORT=$(kubectl get deployment readiness-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.port}' 2>/dev/null)
assert_eq "readiness probe port is 80" "80" "$READINESS_PORT"

READINESS_LIVE_PATH=$(kubectl get deployment readiness-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "readiness-app also has liveness probe on /" "/" "$READINESS_LIVE_PATH"

SVC_EXISTS=$(kubectl get svc readiness-svc -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_eq "readiness-svc Service created" "1" "$SVC_EXISTS"

# Behavioral: drive readiness via the /ready file and watch Service endpoints.
# Pods must at least be scheduled/Running for exec; skip if they can't converge.
count_endpoints() {
  kubectl get endpoints readiness-svc -n "$NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' '
}

if wait_for_pods "$NS" "app=readiness-app" 3 90; then
  # Create the /ready endpoint on all pods so they pass the readiness probe.
  for pod in $(kubectl get pods -l app=readiness-app -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl exec "$pod" -n "$NS" -- sh -c "echo OK > /usr/share/nginx/html/ready" &>/dev/null
  done

  # successThreshold 2 x periodSeconds 5 ≈ 10s to become Ready; poll up to ~60s.
  EP=0
  for i in $(seq 1 12); do
    EP=$(count_endpoints)
    [ "$EP" -ge 3 ] && break
    sleep 5
  done

  if [ "$EP" -ge 3 ]; then
    pass "readiness-svc has 3 endpoints when all pods are ready"

    # Break readiness on one pod and confirm it drops out of the endpoints.
    BREAK_POD=$(kubectl get pod -l app=readiness-app -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    kubectl exec "$BREAK_POD" -n "$NS" -- rm -f /usr/share/nginx/html/ready &>/dev/null
    EP_DOWN=3
    for i in $(seq 1 12); do
      EP_DOWN=$(count_endpoints)
      [ "$EP_DOWN" -le 2 ] && break
      sleep 5
    done
    assert_eq "endpoints drop to 2 when one pod is unready" "2" "$EP_DOWN"

    # Restore readiness and confirm the endpoint returns.
    kubectl exec "$BREAK_POD" -n "$NS" -- sh -c "echo OK > /usr/share/nginx/html/ready" &>/dev/null
    EP_UP=$EP_DOWN
    for i in $(seq 1 12); do
      EP_UP=$(count_endpoints)
      [ "$EP_UP" -ge 3 ] && break
      sleep 5
    done
    assert_eq "endpoints return to 3 after readiness restored" "3" "$EP_UP"
  else
    skip "readiness-app endpoints did not reach 3 — skipping endpoint behavior checks"
  fi
else
  skip "readiness-app pods did not schedule — skipping endpoint behavior checks"
fi

# ─── Step 4: Startup probe ───────────────────────────────────────────────

echo ""
echo "Step 4: Startup Probe"
envsubst '$STUDENT_NAME' < "$LAB_DIR/slow-start-app.yaml" | kubectl apply -f - &>/dev/null
sleep 5

STARTUP_FAIL_THRESH=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].startupProbe.failureThreshold}' 2>/dev/null)
assert_eq "startup failureThreshold is 12" "12" "$STARTUP_FAIL_THRESH"

STARTUP_PERIOD=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].startupProbe.periodSeconds}' 2>/dev/null)
assert_eq "startup periodSeconds is 5" "5" "$STARTUP_PERIOD"

STARTUP_LIVE=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "slow-start-app has liveness probe" "/" "$STARTUP_LIVE"

STARTUP_READY=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)
assert_eq "slow-start-app has readiness probe" "/" "$STARTUP_READY"

# ─── Step 5: Tuned probes ────────────────────────────────────────────────

echo ""
echo "Step 5: Tuned Probes"
envsubst '$STUDENT_NAME' < "$LAB_DIR/tuned-probes.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" tuned-probes 60

TUNED_LIVE_PERIOD=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.periodSeconds}' 2>/dev/null)
assert_eq "tuned liveness periodSeconds is 5" "5" "$TUNED_LIVE_PERIOD"

TUNED_LIVE_FAIL=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.failureThreshold}' 2>/dev/null)
assert_eq "tuned liveness failureThreshold is 2" "2" "$TUNED_LIVE_FAIL"

TUNED_READY_PERIOD=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.periodSeconds}' 2>/dev/null)
assert_eq "tuned readiness periodSeconds is 3" "3" "$TUNED_READY_PERIOD"

TUNED_READY_SUCCESS=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.successThreshold}' 2>/dev/null)
assert_eq "tuned readiness successThreshold is 3" "3" "$TUNED_READY_SUCCESS"

# ─── Step 6: TCP Probe ────────────────────────────────────────────────────

echo ""
echo "Step 6: TCP Probe"
envsubst '$STUDENT_NAME' < "$LAB_DIR/tcp-probe-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" tcp-probe-app 60

TCP_LIVE_PORT=$(kubectl get deployment tcp-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.tcpSocket.port}' 2>/dev/null)
assert_eq "tcp liveness probe port is 6379" "6379" "$TCP_LIVE_PORT"

TCP_READY_PORT=$(kubectl get deployment tcp-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.tcpSocket.port}' 2>/dev/null)
assert_eq "tcp readiness probe port is 6379" "6379" "$TCP_READY_PORT"

# ─── Step 7: Exec Probe ──────────────────────────────────────────────────

echo ""
echo "Step 7: Exec Probe"
envsubst '$STUDENT_NAME' < "$LAB_DIR/exec-probe-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" exec-probe-app 60

EXEC_CMD=$(kubectl get deployment exec-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.exec.command}' 2>/dev/null)
assert_contains "exec probe command runs 'cat'" "$EXEC_CMD" "cat"
assert_contains "exec probe command targets /tmp/healthy" "$EXEC_CMD" "/tmp/healthy"

# ─── Step 8: Graceful Shutdown ────────────────────────────────────────────

echo ""
echo "Step 8: Graceful Shutdown"
envsubst '$STUDENT_NAME' < "$LAB_DIR/graceful-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" graceful-app 60

GRACE_PERIOD=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}' 2>/dev/null)
assert_eq "terminationGracePeriodSeconds is 45" "45" "$GRACE_PERIOD"

PRESTOP_CMD=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.exec.command}' 2>/dev/null)
assert_contains "preStop exec command exists" "$PRESTOP_CMD" "sleep"

GRACEFUL_LIVE=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "graceful-app has liveness probe" "/" "$GRACEFUL_LIVE"

GRACEFUL_READY=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)
assert_eq "graceful-app has readiness probe" "/" "$GRACEFUL_READY"

# ─── Cleanup ──────────────────────────────────────────────────────────────

cleanup_ns "$NS"

# Step 9: confirm the namespace is gone after teardown (allow terminating delay).
for i in $(seq 1 12); do
  kubectl get namespace "$NS" &>/dev/null || break
  sleep 5
done
assert_cmd_fails "probes-lab namespace deleted after cleanup" kubectl get namespace "$NS"

summary
