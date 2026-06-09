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

# ─── Step 2: Liveness probe (HTTP) ───────────────────────────────────────

echo ""
echo "Step 2: Liveness Probe (HTTP)"
envsubst '$STUDENT_NAME' < "$LAB_DIR/liveness-http.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" liveness-http 60

LIVENESS_PATH=$(kubectl get deployment liveness-http -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "liveness probe path is /" "/" "$LIVENESS_PATH"

LIVENESS_PORT=$(kubectl get deployment liveness-http -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.port}' 2>/dev/null)
assert_eq "liveness probe port is 80" "80" "$LIVENESS_PORT"

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
echo "$EXEC_CMD" | grep -q "cat" && assert_eq "exec probe command contains cat" "true" "true" || assert_eq "exec probe command contains cat" "true" "false"

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
summary
