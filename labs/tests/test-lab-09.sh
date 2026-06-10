#!/bin/bash
###############################################################################
# Lab 9 Test: Observability
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-09" && pwd)"
source "$SCRIPT_DIR/lib.sh"
trap 'pkill -f "port-forward.*1808" 2>/dev/null; cleanup_ns "$NS" 2>/dev/null' EXIT

export STUDENT_NAME="test-$$"
NS="obs-lab-$STUDENT_NAME"
echo "=== Lab 9: Observability (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Step 1: Container logs ───────────────────────────────────────────────

echo "Container Logs:"
kubectl run log-generator --image=busybox:1.36 -n "$NS" --restart=Never \
  -- sh -c 'i=0; while true; do echo "INFO request_id=$i status=200"; i=$((i+1)); sleep 1; done' &>/dev/null
wait_for_pod "$NS" log-generator 60
sleep 3

LOGS=$(kubectl logs log-generator -n "$NS" --tail=5 2>/dev/null)
assert_contains "logs --tail returns INFO messages" "$LOGS" "INFO"

LOGS_TS=$(kubectl logs log-generator -n "$NS" --timestamps --tail=3 2>/dev/null)
assert_contains "logs --timestamps adds timestamp prefix" "$LOGS_TS" "Z "

LOGS_SINCE=$(kubectl logs log-generator -n "$NS" --since=10s 2>/dev/null)
assert_contains "logs --since returns recent entries" "$LOGS_SINCE" "request_id"

# ─── Step 1b: Multi-container logs ────────────────────────────────────────

echo ""
echo "Multi-Container Logs:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/multi-container-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" multi-container-app 60
sleep 3

APP_LOG=$(kubectl logs multi-container-app -n "$NS" -c app --tail=3 2>/dev/null)
assert_contains "app container logs via -c app" "$APP_LOG" "APP"

SIDECAR_LOG=$(kubectl logs multi-container-app -n "$NS" -c sidecar --tail=3 2>/dev/null)
assert_contains "sidecar container logs via -c sidecar" "$SIDECAR_LOG" "SIDECAR"

ALL_LOG=$(kubectl logs multi-container-app -n "$NS" --all-containers=true --tail=10 2>/dev/null)
assert_contains "all-containers flag shows app logs" "$ALL_LOG" "APP"
assert_contains "all-containers flag shows sidecar logs" "$ALL_LOG" "SIDECAR"

# ─── Step 2: JSON structured logging ─────────────────────────────────────

echo ""
echo "JSON Structured Logging:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/json-logger.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" json-logger 90
sleep 5

JSON_LOGS=$(kubectl logs -l app=json-logger -n "$NS" --tail=5 2>/dev/null)
assert_contains "json-logger produces output" "$JSON_LOGS" "status"

# Verify logs are valid JSON by piping through jq
# The json-logger printf may split JSON across multiple lines; use jq -s to merge and grab first object
# Get logs from a single pod to avoid interleaving from multiple replicas
JSON_POD=$(kubectl get pods -l app=json-logger -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
JSON_LINE=$(kubectl logs "$JSON_POD" -n "$NS" --tail=5 2>/dev/null | grep -m1 '"status"')
JSON_PARSED=$(echo "$JSON_LINE" | jq '.status' 2>/dev/null)
if [ "$JSON_PARSED" = "200" ]; then
  pass "json-logger output is valid JSON with status=200"
else
  fail "json-logger output not valid JSON (jq returned: $JSON_PARSED from line: $JSON_LINE)"
fi

# Filter with jq select
JSON_SVC=$(echo "$JSON_LINE" | jq -r '.service' 2>/dev/null)
assert_eq "json-logger service field is order-api" "order-api" "$JSON_SVC"

JSON_LEVEL=$(echo "$JSON_LINE" | jq -r '.level' 2>/dev/null)
assert_eq "json-logger level field is info" "info" "$JSON_LEVEL"

# Verify label selector works
JSON_LABEL_LOGS=$(kubectl logs -l app=json-logger -n "$NS" --tail=3 2>/dev/null)
assert_contains "label selector -l app=json-logger works" "$JSON_LABEL_LOGS" "timestamp"

# ─── Step 3: Metrics Server ──────────────────────────────────────────────

echo ""
echo "Metrics Server:"
if kubectl top nodes &>/dev/null; then
  pass "kubectl top nodes works"

  # Verify metrics-server deployment exists
  MS_DEPLOY=$(kubectl get deployment metrics-server -n kube-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$MS_DEPLOY" -ge 1 ]; then
    pass "metrics-server deployment exists in kube-system"
  else
    fail "metrics-server deployment not found in kube-system"
  fi

  # Verify apiservice registered
  APISERVICE=$(kubectl get apiservice v1beta1.metrics.k8s.io --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$APISERVICE" -ge 1 ]; then
    pass "apiservice v1beta1.metrics.k8s.io is registered"
  else
    fail "apiservice v1beta1.metrics.k8s.io not registered"
  fi

  # Deploy stress-test and verify kubectl top pods
  envsubst '$STUDENT_NAME' < "$LAB_DIR/stress-test.yaml" | kubectl apply -f - &>/dev/null
  wait_for_deploy "$NS" stress-test 90

  STRESS_DEPLOY=$(kubectl get deployment stress-test -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  assert_eq "stress-test deployment has 2 ready replicas" "2" "$STRESS_DEPLOY"

  # Give metrics-server time to collect data
  sleep 30

  TOP_OUTPUT=$(kubectl top pods -n "$NS" -l app=stress-test 2>/dev/null)
  if echo "$TOP_OUTPUT" | grep -q "stress-test"; then
    pass "kubectl top pods shows stress-test resource usage"
  else
    skip "metrics-server has not collected stress-test data yet"
  fi

  TOP_SORT=$(kubectl top pods -n "$NS" --sort-by=cpu 2>/dev/null)
  if echo "$TOP_SORT" | grep -q "NAME"; then
    pass "kubectl top pods --sort-by=cpu works"
  else
    skip "kubectl top pods --sort-by=cpu not available"
  fi

  TOP_SORT_MEM=$(kubectl top pods -n "$NS" --sort-by=memory 2>/dev/null)
  if echo "$TOP_SORT_MEM" | grep -q "NAME"; then
    pass "kubectl top pods --sort-by=memory works"
  else
    skip "kubectl top pods --sort-by=memory not available"
  fi

  TOP_CONTAINERS=$(kubectl top pods -n "$NS" --containers 2>/dev/null)
  if echo "$TOP_CONTAINERS" | grep -q "NAME"; then
    pass "kubectl top pods --containers works"
  else
    skip "kubectl top pods --containers not available"
  fi
else
  skip "metrics-server not responding (top nodes)"
  skip "metrics-server deployment check (metrics-server unavailable)"
  skip "apiservice check (metrics-server unavailable)"
  skip "stress-test metrics (metrics-server unavailable)"
  skip "top pods sort cpu (metrics-server unavailable)"
  skip "top pods sort memory (metrics-server unavailable)"
  skip "top pods containers (metrics-server unavailable)"
fi

# ─── Step 9 (before Prometheus): Buggy app debugging ─────────────────────

echo ""
echo "Buggy App Debugging:"
envsubst '$STUDENT_NAME' < "$LAB_DIR/buggy-app.yaml" | kubectl apply -f - &>/dev/null
sleep 5

# The buggy app exits with code 137 after 5-15 seconds; wait for restarts
BUGGY_RUNNING=false
for i in $(seq 1 12); do
  BUGGY_STATUS=$(kubectl get pods -l app=buggy-app -n "$NS" --no-headers 2>/dev/null | head -1)
  if echo "$BUGGY_STATUS" | grep -qE "CrashLoopBackOff|Error|OOMKilled"; then
    BUGGY_RUNNING=true
    break
  fi
  sleep 5
done

if [ "$BUGGY_RUNNING" = true ]; then
  pass "buggy-app enters CrashLoopBackOff or Error state"
else
  # Even if not yet crashlooping, check restarts
  RESTARTS=$(kubectl get pods -l app=buggy-app -n "$NS" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
  if [ "${RESTARTS:-0}" -gt 0 ]; then
    pass "buggy-app has restarted ($RESTARTS times)"
  else
    fail "buggy-app did not crash or restart within timeout"
  fi
fi

# Check exit code 137
EXIT_CODE=$(kubectl get pod -l app=buggy-app -n "$NS" -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null)
assert_eq "buggy-app exit code is 137 (OOMKilled/SIGKILL)" "137" "$EXIT_CODE"

# Check --previous flag retrieves pre-crash logs. Two transient conditions must
# be tolerated: (1) `--previous` needs a prior instance (restartCount >= 1) —
# lastState.terminated alone, used for the exit-code check above, is set during
# the first CrashLoopBackOff before any restart; (2) while the kubelet GCs the
# dead container, `kubectl logs --previous` intermittently prints "unable to
# retrieve container logs for containerd://..." to STDOUT (so it's non-empty).
# Retry until the logs actually contain the expected pre-crash content.
PREV_OK=false
for i in $(seq 1 24); do
  RC=$(kubectl get pod -l app=buggy-app -n "$NS" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
  if [ "${RC:-0}" -ge 1 ]; then
    PREV_LOGS=$(kubectl logs -l app=buggy-app -n "$NS" --previous --tail=5 2>/dev/null)
    if echo "$PREV_LOGS" | grep -qE "Starting app|ERROR"; then PREV_OK=true; break; fi
  fi
  sleep 5
done
if [ "$PREV_OK" = true ]; then
  pass "kubectl logs --previous retrieves pre-crash logs"
else
  fail "kubectl logs --previous did not return expected content"
fi

# Check events show warnings
EVENTS=$(kubectl get events -n "$NS" --sort-by='.lastTimestamp' 2>/dev/null)
assert_contains "events show BackOff for buggy-app" "$EVENTS" "BackOff"

# Check describe shows terminated state
DESCRIBE=$(kubectl describe pod -l app=buggy-app -n "$NS" 2>/dev/null)
assert_contains "describe shows terminated state" "$DESCRIBE" "Terminated"

# ─── Buggy App PromQL Queries ─────────────────────────────────────────────

echo ""
echo "Buggy App PromQL Queries:"
if kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q Running; then
  kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 18083:9090 &>/dev/null &
  PF_PID=$!
  sleep 3

  # Query restart count for buggy-app namespace
  PROM_RESTART_INC=$(curl -s "http://localhost:18083/api/v1/query" \
    --data-urlencode "query=increase(kube_pod_container_status_restarts_total{namespace=\"$NS\"}[30m])" 2>/dev/null)
  assert_contains "PromQL buggy-app restart increase query returns success" "$PROM_RESTART_INC" "success"

  # Query OOMKilled reason for buggy-app namespace
  PROM_OOMKILLED=$(curl -s "http://localhost:18083/api/v1/query" \
    --data-urlencode "query=kube_pod_container_status_last_terminated_reason{namespace=\"$NS\",reason=\"OOMKilled\"}" 2>/dev/null)
  assert_contains "PromQL buggy-app OOMKilled query returns success" "$PROM_OOMKILLED" "success"

  kill $PF_PID &>/dev/null
else
  skip "PromQL buggy-app restart query (prometheus unavailable)"
  skip "PromQL buggy-app OOMKilled query (prometheus unavailable)"
fi

# ─── Step 4-5: Prometheus ─────────────────────────────────────────────────

echo ""
echo "Prometheus:"
if kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q Running; then
  kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 18080:9090 &>/dev/null &
  PF_PID=$!
  sleep 3

  # Basic up query
  PROM_UP=$(curl -s "http://localhost:18080/api/v1/query" --data-urlencode 'query=up' 2>/dev/null)
  assert_contains "PromQL 'up' query returns success" "$PROM_UP" "success"

  # CPU usage per node
  PROM_CPU=$(curl -s "http://localhost:18080/api/v1/query" \
    --data-urlencode 'query=sum(rate(node_cpu_seconds_total{mode!="idle"}[5m])) by (instance)' 2>/dev/null)
  assert_contains "PromQL node CPU query returns success" "$PROM_CPU" "success"

  # Memory usage percentage
  PROM_MEM=$(curl -s "http://localhost:18080/api/v1/query" \
    --data-urlencode 'query=100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))' 2>/dev/null)
  assert_contains "PromQL node memory query returns success" "$PROM_MEM" "success"

  # Pod CPU usage in our namespace
  PROM_POD_CPU=$(curl -s "http://localhost:18080/api/v1/query" \
    --data-urlencode "query=sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\"}[5m])) by (pod)" 2>/dev/null)
  assert_contains "PromQL pod CPU query returns success" "$PROM_POD_CPU" "success"

  # Container restart count
  PROM_RESTARTS=$(curl -s "http://localhost:18080/api/v1/query" \
    --data-urlencode 'query=sum(kube_pod_container_status_restarts_total) by (namespace, pod)' 2>/dev/null)
  assert_contains "PromQL restart count query returns success" "$PROM_RESTARTS" "success"

  # Pod count per namespace
  PROM_POD_COUNT=$(curl -s "http://localhost:18080/api/v1/query" \
    --data-urlencode 'query=count(kube_pod_info) by (namespace)' 2>/dev/null)
  assert_contains "PromQL pod count query returns success" "$PROM_POD_COUNT" "success"

  # CrashLoopBackOff query
  PROM_CRASH=$(curl -s "http://localhost:18080/api/v1/query" \
    --data-urlencode 'query=kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}' 2>/dev/null)
  assert_contains "PromQL CrashLoopBackOff query returns success" "$PROM_CRASH" "success"

  # Top memory consumers
  PROM_TOPMEM=$(curl -s "http://localhost:18080/api/v1/query" \
    --data-urlencode 'query=topk(5, container_memory_working_set_bytes{container!="", container!="POD"})' 2>/dev/null)
  assert_contains "PromQL top memory query returns success" "$PROM_TOPMEM" "success"

  kill $PF_PID &>/dev/null
else
  skip "prometheus not running"
  skip "PromQL node CPU query (prometheus unavailable)"
  skip "PromQL node memory query (prometheus unavailable)"
  skip "PromQL pod CPU query (prometheus unavailable)"
  skip "PromQL restart count query (prometheus unavailable)"
  skip "PromQL pod count query (prometheus unavailable)"
  skip "PromQL CrashLoopBackOff query (prometheus unavailable)"
  skip "PromQL top memory query (prometheus unavailable)"
fi

# ─── Step 6: Grafana ─────────────────────────────────────────────────────

echo ""
echo "Grafana:"
if kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -q Running; then
  kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-stack-grafana 18081:80 &>/dev/null &
  PF_PID=$!
  sleep 3

  GF_DS=$(curl -s -u admin:admin "http://localhost:18081/api/datasources" 2>/dev/null)
  assert_contains "grafana datasources include Prometheus" "$GF_DS" "Prometheus"

  DASH=$(curl -s -u admin:admin "http://localhost:18081/api/search" 2>/dev/null | jq 'length' 2>/dev/null)
  if [ "${DASH:-0}" -gt 0 ]; then
    pass "grafana has $DASH dashboards"
  else
    fail "no grafana dashboards found"
  fi

  # Verify dashboard list returns titles
  DASH_TITLES=$(curl -s -u admin:admin "http://localhost:18081/api/search" 2>/dev/null | jq -r '.[].title' 2>/dev/null)
  if [ -n "$DASH_TITLES" ]; then
    pass "grafana dashboard titles are accessible"
  else
    fail "grafana dashboard titles not accessible"
  fi

  kill $PF_PID &>/dev/null
else
  skip "grafana not running"
  skip "grafana dashboards (grafana unavailable)"
  skip "grafana dashboard titles (grafana unavailable)"
fi

# ─── CloudWatch Container Insights (optional) ────────────────────────────

echo ""
echo "CloudWatch Container Insights:"
CW_DS=$(kubectl get daemonset -n amazon-cloudwatch --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${CW_DS:-0}" -gt 0 ]; then
  pass "CloudWatch Container Insights daemonset found in amazon-cloudwatch namespace"
else
  skip "CloudWatch Container Insights not installed (optional)"
fi

# ─── Step 7: PrometheusRule ───────────────────────────────────────────────

echo ""
echo "PrometheusRule Alerting:"
if kubectl get crd prometheusrules.monitoring.coreos.com &>/dev/null; then
  envsubst '$STUDENT_NAME' < "$LAB_DIR/prom-rule.yaml" | kubectl apply -f - &>/dev/null
  sleep 3

  RULE=$(kubectl get prometheusrule "pod-restart-alert-$STUDENT_NAME" -n monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "PrometheusRule resource created" "1" "$RULE"

  # Verify rule labels include release for operator pickup
  RULE_LABEL=$(kubectl get prometheusrule "pod-restart-alert-$STUDENT_NAME" -n monitoring -o jsonpath='{.metadata.labels.release}' 2>/dev/null)
  assert_eq "PrometheusRule has release label" "kube-prometheus-stack" "$RULE_LABEL"

  # Verify rule group name
  RULE_GROUP=$(kubectl get prometheusrule "pod-restart-alert-$STUDENT_NAME" -n monitoring -o jsonpath='{.spec.groups[0].name}' 2>/dev/null)
  assert_eq "PrometheusRule group name is pod-restarts" "pod-restarts" "$RULE_GROUP"

  # Verify both alert names exist
  ALERT1=$(kubectl get prometheusrule "pod-restart-alert-$STUDENT_NAME" -n monitoring -o jsonpath='{.spec.groups[0].rules[0].alert}' 2>/dev/null)
  assert_eq "first alert is HighPodRestartCount" "HighPodRestartCount" "$ALERT1"

  ALERT2=$(kubectl get prometheusrule "pod-restart-alert-$STUDENT_NAME" -n monitoring -o jsonpath='{.spec.groups[0].rules[1].alert}' 2>/dev/null)
  assert_eq "second alert is PodCrashLooping" "PodCrashLooping" "$ALERT2"

  # Verify Prometheus picked up the rule via rules API
  if kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q Running; then
    kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 18082:9090 &>/dev/null &
    PF_PID=$!
    sleep 5

    # Wait up to 120s for Prometheus to pick up the rule (the operator writes
    # the rules ConfigMap, then prometheus-config-reloader reloads on its own
    # interval — on a freshly-reconciled cluster this can exceed 60s).
    RULE_FOUND=false
    for i in $(seq 1 24); do
      RULES_API=$(curl -s "http://localhost:18082/api/v1/rules" 2>/dev/null)
      if echo "$RULES_API" | jq -e '.data.groups[].rules[] | select(.name == "HighPodRestartCount")' &>/dev/null; then
        RULE_FOUND=true
        break
      fi
      sleep 5
    done

    if [ "$RULE_FOUND" = true ]; then
      pass "Prometheus rules API contains HighPodRestartCount"
    else
      fail "HighPodRestartCount not found in Prometheus rules API within 120s"
    fi

    kill $PF_PID &>/dev/null
  else
    skip "prometheus not running (rule API check)"
  fi

  kubectl delete prometheusrule "pod-restart-alert-$STUDENT_NAME" -n monitoring &>/dev/null
else
  skip "PrometheusRule CRD not installed"
  skip "PrometheusRule labels (CRD unavailable)"
  skip "PrometheusRule group (CRD unavailable)"
  skip "alert names (CRD unavailable)"
  skip "Prometheus rules API (CRD unavailable)"
fi

# ─── Step 10: Distributed Tracing with Jaeger ────────────────────────────

echo ""
echo "Distributed Tracing (Jaeger):"
if kubectl get pods -n monitoring -l app.kubernetes.io/name=jaeger --no-headers 2>/dev/null | grep -q Running; then
  pass "Jaeger pod running in monitoring namespace"

  # Verify Jaeger query service exists
  JAEGER_SVC=$(kubectl get svc -n monitoring -l app.kubernetes.io/name=jaeger --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${JAEGER_SVC:-0}" -gt 0 ]; then
    pass "Jaeger service exists in monitoring namespace"
  else
    fail "Jaeger service not found"
  fi

  # Deploy traced app
  envsubst '$STUDENT_NAME' < "$LAB_DIR/traced-app.yaml" | kubectl apply -f - &>/dev/null
  wait_for_deploy "$NS" traced-app 90

  # Verify OTel env vars are configured
  OTEL_SVC=$(kubectl get pod -l app=traced-app -n "$NS" \
    -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="OTEL_SERVICE_NAME")].value}' 2>/dev/null)
  assert_contains "traced-app has OTEL_SERVICE_NAME" "$OTEL_SVC" "traced-app"

  OTEL_ENDPOINT=$(kubectl get pod -l app=traced-app -n "$NS" \
    -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="OTEL_EXPORTER_OTLP_ENDPOINT")].value}' 2>/dev/null)
  # Assert the exact all-in-one service DNS name. The Jaeger HelmRelease runs
  # allInOne with collector/query/agent disabled, so the only service is
  # `monitoring-jaeger` — a `-collector`/`-query` suffix would be wrong.
  assert_contains "traced-app OTLP endpoint targets the Jaeger all-in-one service" "$OTEL_ENDPOINT" "monitoring-jaeger.monitoring.svc.cluster.local:4317"

  OTEL_SAMPLER=$(kubectl get pod -l app=traced-app -n "$NS" \
    -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="OTEL_TRACES_SAMPLER")].value}' 2>/dev/null)
  assert_eq "traced-app sampler is always_on" "always_on" "$OTEL_SAMPLER"

  OTEL_ATTRS=$(kubectl get pod -l app=traced-app -n "$NS" \
    -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="OTEL_RESOURCE_ATTRIBUTES")].value}' 2>/dev/null)
  assert_contains "traced-app resource attributes include environment" "$OTEL_ATTRS" "deployment.environment"

  # Verify traced-app service exists
  assert_cmd "traced-app-svc exists" kubectl get svc traced-app-svc -n "$NS"
else
  skip "Jaeger not running — skipping tracing tests"
  skip "Jaeger service (Jaeger unavailable)"
  skip "traced-app deployment (Jaeger unavailable)"
  skip "traced-app OTel env vars (Jaeger unavailable)"
  skip "traced-app OTLP endpoint (Jaeger unavailable)"
  skip "traced-app sampler (Jaeger unavailable)"
  skip "traced-app resource attributes (Jaeger unavailable)"
  skip "traced-app service (Jaeger unavailable)"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────

summary
