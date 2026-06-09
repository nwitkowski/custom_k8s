# Lab 9: Observability
### Monitoring, Logging, and Debugging Kubernetes Workloads
**Intermediate Kubernetes — Module 9 of 13**

---

## Lab Overview

### What You'll Learn

- Container log collection and analysis
- Prometheus metrics and PromQL queries
- Grafana dashboards for visualization
- Custom alerting rules
- *Optional:* Debug a failing application using observability tools
- *Optional:* Explore distributed tracing with Jaeger and OpenTelemetry

### Lab Details

- **Duration:** ~45-55 minutes

> **Note:** Step 9 is an optional stretch goal for students who finish early.
- **Difficulty:** Intermediate
- **Prerequisites:** Lab 1 (cluster access configured)

> ⚠️ **Note:** Verify metrics-server is running before you begin.

---

## Environment Setup

```bash
cd ~/environment/verisign_k8s/labs/lab-09
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
```

> ⚠️ **Important:** Your `STUDENT_NAME` ensures your resources don't conflict with other students on this shared cluster.

---

## Step 1: Explore Container Logs with kubectl

Create a namespace and deploy a log-generating pod:

```bash
kubectl create namespace obs-lab-$STUDENT_NAME
kubectl config set-context --current --namespace=obs-lab-$STUDENT_NAME
```

```bash
kubectl run log-generator --image=busybox \
  --restart=Never -- \
  sh -c 'i=0; while true; do
    echo "$(date +%Y-%m-%dT%H:%M:%S) INFO  request_id=$i \
      status=200 path=/api/health duration=12ms";
    echo "$(date +%Y-%m-%dT%H:%M:%S) DEBUG request_id=$i cache_hit=true";
    if [ $((i % 10)) -eq 0 ]; then
      echo "$(date +%Y-%m-%dT%H:%M:%S) WARN  request_id=$i \
        high_latency=true duration=1500ms";
    fi;
    i=$((i+1)); sleep 2;
  done'

kubectl wait --for=condition=Ready pod/log-generator --timeout=30s
```

### Explore kubectl logs Flags

```bash
kubectl logs log-generator --tail=20
kubectl logs log-generator -f
kubectl logs log-generator --since=5m
kubectl logs log-generator --timestamps
```

> 💡 **Key Flags:** `-f` to follow, `--previous` for crashed containers, `-c <name>` for multi-container pods, `--tail=N` and `--since=duration` to filter.

### Multi-Container Pod Logs

<!-- Creates a Pod with two containers (app + sidecar) for log exploration -->
```bash
envsubst '$STUDENT_NAME' < multi-container-app.yaml | kubectl apply -f -
```

```bash
kubectl logs multi-container-app -c app
kubectl logs multi-container-app -c sidecar
kubectl logs multi-container-app --all-containers=true
```

---

## Step 2: Structured JSON Logging

<!-- Creates a Deployment that outputs structured JSON logs -->
```bash
envsubst '$STUDENT_NAME' < json-logger.yaml | kubectl apply -f -
```

### View and Filter JSON Logs

```bash
kubectl logs deployment/json-logger --all-containers=true --tail=5
kubectl logs deployment/json-logger -f --max-log-requests=5
kubectl logs -l app=json-logger --tail=10
```

> 💡 **Tip:** Pipe JSON logs through `jq` for local filtering:
> ```bash
> kubectl logs -l app=json-logger --tail=20 | jq 'select(.status != 200)'
> ```

---

## Step 3: Examine Metrics Server Data

```bash
kubectl get deployment metrics-server -n kube-system
kubectl get apiservice v1beta1.metrics.k8s.io
```

> 💡 If not installed: `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml`

### kubectl top: Node and Pod Metrics

```bash
kubectl top nodes
kubectl top pods
kubectl top pods --sort-by=cpu
kubectl top pods --sort-by=memory
kubectl top pods --containers
```

### Deploy a Resource-Intensive Workload

<!-- Creates a CPU-intensive Deployment for metrics observation -->
```bash
envsubst '$STUDENT_NAME' < stress-test.yaml | kubectl apply -f -
```

```bash
sleep 30
kubectl top pods -l app=stress-test --containers
```

> ✅ **Checkpoint:** You can view logs with `-f`, `--tail`, `--since`, target containers with `-c`, and `kubectl top` returns data for nodes and pods.

---

## Step 4: Verify the Prometheus Stack

The monitoring stack (Prometheus, Grafana, Alertmanager) has been pre-installed. Verify it is running:

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

> ⚠️ **Important:** Do not reinstall the monitoring stack.

---

## Step 5: Query Prometheus Metrics

```bash
kubectl port-forward -n monitoring \
  svc/monitoring-kube-prometheus-prometheus 8080:9090 &
```

> ⚠️ **Cloud9:** Click **Preview → Preview Running Application** (top menu) to open the Prometheus UI. Or use `curl` in a second terminal tab.

### Run PromQL Queries via curl

```bash
# Total CPU usage per node
curl -s 'http://localhost:8080/api/v1/query' \
  --data-urlencode 'query=sum(rate(node_cpu_seconds_total{mode!="idle"}[5m])) by (instance)' | jq .

# Memory usage percentage per node
curl -s 'http://localhost:8080/api/v1/query' \
  --data-urlencode 'query=100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))' | jq .

# Pod CPU usage in your namespace
curl -s 'http://localhost:8080/api/v1/query' \
  --data-urlencode "query=sum(rate(container_cpu_usage_seconds_total{namespace=\"obs-lab-$STUDENT_NAME\"}[5m])) by (pod)" | jq .

# Container restart count
curl -s 'http://localhost:8080/api/v1/query' \
  --data-urlencode 'query=sum(kube_pod_container_status_restarts_total) by (namespace, pod)' | jq .
```

### Useful Cluster Queries

```bash
# Pod count per namespace
curl -s 'http://localhost:8080/api/v1/query' \
  --data-urlencode 'query=count(kube_pod_info) by (namespace)' | jq .

# Pods in CrashLoopBackOff
curl -s 'http://localhost:8080/api/v1/query' \
  --data-urlencode 'query=kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}' | jq .

# Top 5 memory consumers
curl -s 'http://localhost:8080/api/v1/query' \
  --data-urlencode 'query=topk(5, container_memory_working_set_bytes{container!="", container!="POD"})' | jq .
```

---

## Step 6: Explore Grafana Dashboards

Stop the Prometheus port-forward first, then forward Grafana on port 8080:

```bash
pkill -f "port-forward.*8080" 2>/dev/null
kubectl port-forward -n monitoring \
  svc/monitoring-kube-prometheus-stack-grafana 8080:80 &
```

Login: `admin` / `admin`

### Verify Grafana via API

```bash
# List available dashboards
curl -s -u admin:admin http://localhost:8080/api/search | jq '.[].title'

# Check datasources
curl -s -u admin:admin http://localhost:8080/api/datasources | jq '.[].name'
```

### Exercise: Investigate the stress-test Workload

In the Grafana UI (Cloud9 Preview or browser), navigate to:

1. **Dashboards → Kubernetes / Compute Resources / Namespace (Pods)**
2. Select namespace: `obs-lab-$STUDENT_NAME`
3. Locate the `stress-test` pods and note their CPU usage
4. Click a pod name to drill into the per-pod dashboard

---

## Step 7: Create a Custom PrometheusRule Alert

Review `prom-rule.yaml` — it defines two alerting rules for pod restart detection:

```bash
envsubst '$STUDENT_NAME' < prom-rule.yaml | kubectl apply -f -
```

> 💡 The `labels.release` is the conventional way to tag a rule for the kube-prometheus-stack operator. This platform configures the operator to select **all** PrometheusRules (`ruleSelectorNilUsesHelmValues: false`), so the rule is picked up regardless — the label is included as good practice.

```bash
kubectl get prometheusrules -n monitoring

# Verify the rule was picked up by Prometheus (may take up to 60s)
pkill -f "port-forward.*8080" 2>/dev/null
kubectl port-forward -n monitoring \
  svc/monitoring-kube-prometheus-prometheus 8080:9090 &
sleep 5
curl -s 'http://localhost:8080/api/v1/rules' | jq '.data.groups[].rules[] | select(.name | test("pod"))'
```

> ✅ **Checkpoint:** You should see the `HighPodRestartCount` and `PodCrashLooping` rules in the output.

---

## Step 8: CloudWatch Container Insights (Optional)

```bash
kubectl get daemonset -n amazon-cloudwatch
kubectl get pods -n amazon-cloudwatch
```

> 📝 If not enabled on your cluster, continue to the next step.

---

---

## Optional Stretch Goals

> These exercises cover additional topics from the presentation. Complete them if you finish the core lab early.

### Step 9: Debug a Failing Application

<!-- Creates a Deployment that simulates OOM crashes for debugging practice -->
```bash
envsubst '$STUDENT_NAME' < buggy-app.yaml | kubectl apply -f -
```

### Systematic Debugging

```bash
# Events
kubectl get pods -l app=buggy-app
kubectl get events --sort-by='.lastTimestamp' \
  -n obs-lab-$STUDENT_NAME | tail -20
kubectl describe pod -l app=buggy-app | grep -A 10 "State:"

# Logs (use --previous for crashed containers)
kubectl logs -l app=buggy-app --tail=20
kubectl logs -l app=buggy-app --previous --tail=20

# Metrics
kubectl top pods -l app=buggy-app
```

In Prometheus, query restart count and OOMKilled status:

```promql
increase(kube_pod_container_status_restarts_total{
  namespace="obs-lab-$STUDENT_NAME", pod=~"buggy-app.*"
}[30m])

kube_pod_container_status_last_terminated_reason{
  namespace="obs-lab-$STUDENT_NAME",
  reason="OOMKilled"
}
```

> ✅ **Checkpoint:** The container exceeds its 32Mi memory limit, so the kubelet records `OOMKilled` as the termination reason with exit code 137 (SIGKILL) — the `OOMKilled` query above returns a data point. The `--previous` flag shows logs from before the crash.

---

### Step 10: Distributed Tracing with Jaeger

Jaeger has been pre-installed as part of the monitoring stack. Verify it's running:

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=jaeger
kubectl get svc -n monitoring -l app.kubernetes.io/name=jaeger
```

### Deploy a Traced Application

This app is configured with OpenTelemetry environment variables pointing to the Jaeger collector:

```bash
envsubst '$STUDENT_NAME' < traced-app.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod -l app=traced-app \
  -n obs-lab-$STUDENT_NAME --timeout=60s
```

### Inspect OTel Configuration

```bash
kubectl get pod -l app=traced-app -n obs-lab-$STUDENT_NAME \
  -o jsonpath='{.items[0].spec.containers[0].env}' | jq .
```

> ✅ **Checkpoint:** The pod has these OTel environment variables:
> - `OTEL_SERVICE_NAME` — identifies this service in traces
> - `OTEL_EXPORTER_OTLP_ENDPOINT` — points to Jaeger's OTLP collector
> - `OTEL_TRACES_SAMPLER` — set to `always_on` for lab visibility
> - `OTEL_RESOURCE_ATTRIBUTES` — adds custom metadata to every span

### View the Jaeger UI

```bash
pkill -f "port-forward.*8080" 2>/dev/null
kubectl port-forward -n monitoring svc/monitoring-jaeger 8080:16686 &
```

> ⚠️ **Cloud9:** Click **Preview → Preview Running Application** to open the Jaeger UI. Select a service from the dropdown to view traces.

> **Key concepts:** A **trace** represents an end-to-end request. Each trace contains **spans** — individual operations with timing, status, and metadata. In microservices, spans from different services are correlated by a shared trace ID propagated in HTTP headers.

---

## Clean Up

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace obs-lab-$STUDENT_NAME
kubectl delete prometheusrule pod-restart-alert-$STUDENT_NAME -n monitoring --ignore-not-found
pkill -f "port-forward.*8080" 2>/dev/null
```

> 📝 Keep the monitoring namespace installed -- it will be useful in subsequent labs.

---

## Summary

- **Logging:** Log to stdout/stderr in structured JSON; use `--previous` for crashed containers
- **Metrics:** Metrics Server powers `kubectl top`; Prometheus provides deep metric collection
- **PromQL:** Master `rate()`, `sum() by`, and range vectors for effective monitoring
- **Grafana:** Pre-built dashboards provide immediate cluster visibility
- **Alerting:** PrometheusRule CRDs define alerting conditions
- **Debugging:** Follow Events > Logs > Metrics > Describe
- **Tracing:** OpenTelemetry env vars configure apps to send spans to Jaeger for end-to-end request visibility

---

*Lab 9 Complete — Up Next: Lab 10 — Health Checks and Probes*
