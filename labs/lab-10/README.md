# Lab 10: Health Checks and Probes
### Liveness, Readiness, and Startup Probes for Resilient Workloads
**Intermediate Kubernetes — Module 10 of 13**

---

## Lab Overview

### What You'll Learn

- Why probes matter (no-probes baseline)
- HTTP liveness probes and automatic restarts
- Readiness probes and Service endpoint management
- Startup probes for slow-starting applications
- Tuning probe parameters for faster detection
- *Optional:* TCP socket probes for non-HTTP services
- *Optional:* Exec probes for custom health checks
- *Optional:* Graceful shutdown with preStop hooks

### Lab Details

- **Duration:** ~25-35 minutes

> **Note:** Steps 6-8 are optional stretch goals for students who finish early.
- **Difficulty:** Intermediate
- **Prerequisites:** Lab 1 (cluster access configured)

> 💡 **Context:** Probes tie directly into the observability skills from Lab 9 — they generate events and metrics you can monitor.

---

## Three Types of Probes

| Probe | Question It Answers | On Failure |
|-------|-------------------|------------|
| 💚 **Liveness** | Is the container **alive**? | Kubernetes **restarts** the container |
| 💙 **Readiness** | Can it **serve traffic**? | Removed from **Service endpoints** |
| 💛 **Startup** | Has it **finished starting**? | Container is **killed** (liveness/readiness paused until success) |

> 📝 **Key Concept:** Liveness and readiness probes are disabled until the startup probe succeeds. This prevents premature kills during slow initialization.

---

## Environment Setup

Set your student identifier (use your first name or assigned number):

```bash
cd ~/environment/custom_k8s/labs/lab-10
# Set your unique student name
export STUDENT_NAME=<usernumber>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `$STUDENT_NAME` ensures your resources don't conflict with others.

```bash
# Create the lab namespace
kubectl create namespace probes-lab-$STUDENT_NAME

# Set as the current context
kubectl config set-context --current --namespace=probes-lab-$STUDENT_NAME
```

---

## Step 1: Deploy an App Without Probes

<!-- Creates a basic nginx Deployment with no health probes -->
```bash
envsubst '$STUDENT_NAME' < no-probes-app.yaml | kubectl apply -f -
```

### Simulate a Failure

```bash
# Verify the app is running
kubectl get pods -l app=no-probes-app
curl_pod=$(kubectl get pod -l app=no-probes-app -o \
  jsonpath='{.items[0].metadata.name}')

# Simulate nginx becoming unresponsive (delete the config)
kubectl exec $curl_pod -- sh -c "rm \
  /etc/nginx/conf.d/default.conf && nginx -s reload"

# Try to access the service — it will fail but the pod stays "Running"
kubectl exec $curl_pod -- curl -s -o /dev/null -w "%{http_code}" localhost:80
```

> ⚠️ **Problem:** The pod shows `Running` and `1/1 Ready` even though it returns errors. Without probes, Kubernetes has no way to detect this failure.

---

## Step 2: Add an HTTP Liveness Probe

<!-- Creates an nginx Deployment with an HTTP liveness probe on / -->
```bash
envsubst '$STUDENT_NAME' < liveness-http.yaml | kubectl apply -f -
```

> 💡 **Probe defaults:** `failureThreshold: 3`, `timeoutSeconds: 1`, `periodSeconds: 10`. Any HTTP status 200–399 counts as success.

### Test the Liveness Probe

```bash
# Get a pod name
LIVE_POD=$(kubectl get pod -l app=liveness-http \
  -o jsonpath='{.items[0].metadata.name}')

# Make the app unhealthy by deleting the index page
kubectl exec $LIVE_POD -- rm /usr/share/nginx/html/index.html

# Watch the pod — it will be restarted after ~30 seconds
# (3 failures x 10 second period)
kubectl get pods -l app=liveness-http -w
```

> ✅ **Expected:** The `RESTARTS` column increments. Kubernetes detected the liveness failure and restarted the container. After restart, nginx returns with the default index page intact.

```bash
# Check the events to see probe failure details
kubectl describe pod $LIVE_POD | grep -A 5 "Liveness"
```

---

## Step 3: Add a Readiness Probe

<!-- Creates a Deployment with readiness + liveness probes and a Service -->
```bash
envsubst '$STUDENT_NAME' < readiness-app.yaml | kubectl apply -f -
```

> 💡 The readiness probe checks `/ready` while the liveness probe checks `/`. The `successThreshold` of 2 means the pod must pass two consecutive checks before being added to the endpoint list.

### Configure the Ready Endpoint

```bash
# Create the /ready endpoint on all pods
for pod in $(kubectl get pods -l app=readiness-app \
  -o jsonpath='{.items[*].metadata.name}'); do
  kubectl exec $pod -- sh -c \
    "mkdir -p /usr/share/nginx/html && echo 'OK' > /usr/share/nginx/html/ready"
done

# Verify pods become ready
kubectl get pods -l app=readiness-app

# Verify endpoints are populated
kubectl get endpoints readiness-svc
```

> ✅ **Expected:** All 3 pods show `1/1 Ready` and the endpoints list shows 3 IP addresses.

### Test Readiness Failure

```bash
# Make one pod unready by removing the /ready file
READY_POD=$(kubectl get pod -l app=readiness-app \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec $READY_POD -- rm /usr/share/nginx/html/ready

# Watch the pod become NotReady
kubectl get pods -l app=readiness-app -w

# Check endpoints — the unready pod is REMOVED
kubectl get endpoints readiness-svc
```

> ✅ **Expected:** The pod shows `0/1 Running` (not ready, but NOT restarted). Endpoints now show only 2 IP addresses.

### Restore Readiness

```bash
# Restore the /ready endpoint
kubectl exec $READY_POD -- sh -c \
  "echo 'OK' > /usr/share/nginx/html/ready"

# Watch it become Ready again (requires 2 successes due to successThreshold)
kubectl get pods -l app=readiness-app -w

# Verify endpoints are restored
kubectl get endpoints readiness-svc
```

> ✅ **Expected:** After ~10 seconds (2 successful checks at 5s intervals), the pod returns to `1/1 Ready` and its IP reappears in the endpoints list.

---

## Step 4: Startup Probes for Slow-Starting Apps

<!-- Creates a slow-starting app with startup, liveness, and readiness probes -->
```bash
envsubst '$STUDENT_NAME' < slow-start-app.yaml | kubectl apply -f -
```

> 💡 The startup probe allows up to 60 seconds (12 failures x 5 seconds) for the application to start. During this time, liveness and readiness probes are disabled.

### Observe Startup Behavior

```bash
# Watch the pod start up
kubectl get pods -l app=slow-start-app -w
```

> ✅ **Expected Timeline:**
> - **0–5s:** Container starting, startup probe not yet active
> - **5–30s:** Startup probe fails (app still initializing) — this is OK
> - **~35s:** App becomes responsive, startup probe passes
> - **~35s+:** Liveness and readiness probes begin

> ⚠️ **Without a Startup Probe:** The liveness probe would kill the container after 3 failures (30 seconds), before the app finishes initializing!

---

## Step 5: Tune Probe Parameters

### Probe Parameter Reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| `initialDelaySeconds` | 0 | Seconds to wait before first probe |
| `periodSeconds` | 10 | How often to perform the probe |
| `timeoutSeconds` | 1 | Seconds before probe times out |
| `failureThreshold` | 3 | Consecutive failures to declare unhealthy |
| `successThreshold` | 1 | Consecutive successes to declare healthy |

> 📝 **Detection Time Formula:** Time to detect failure = `periodSeconds x failureThreshold`. With defaults: 10 x 3 = **30 seconds**.

> 💡 `successThreshold` must be 1 for liveness and startup probes. It can be higher for readiness probes to prevent flapping.

### Deploy Tuned Probes

<!-- Creates a Deployment with tuned liveness/readiness probe parameters -->
```bash
envsubst '$STUDENT_NAME' < tuned-probes.yaml | kubectl apply -f -
```

> 💡 **Analysis:**
> - Liveness detection time: 5s x 2 = **10 seconds** (vs 30s default)
> - Readiness detection time: 3s x 2 = **6 seconds**
> - Readiness recovery time: 3s x 3 = **9 seconds** (higher successThreshold)
>
> Faster probes catch failures quicker but increase kubelet overhead. For most workloads, checking every 5–10 seconds is sufficient.

---

---

## Optional Stretch Goals

> These exercises cover additional topics from the presentation. Complete them if you finish the core lab early.

### Step 6: TCP Socket Probes

TCP probes check whether a port is open — useful for non-HTTP services like Redis, databases, or message queues:

```bash
envsubst '$STUDENT_NAME' < tcp-probe-app.yaml | kubectl apply -f -

kubectl get pods -l app=tcp-probe-app
kubectl describe pod -l app=tcp-probe-app | grep -A 3 "Liveness\|Readiness"
```

> ✅ **Checkpoint:** Both liveness and readiness probes use `tcpSocket` on port 6379.

---

### Step 7: Exec Probes

Exec probes run a command inside the container — useful for custom health checks:

```bash
envsubst '$STUDENT_NAME' < exec-probe-app.yaml | kubectl apply -f -

kubectl get pods -l app=exec-probe-app
kubectl describe pod -l app=exec-probe-app | grep -A 3 "Liveness"
```

> ✅ **Checkpoint:** The liveness probe runs `cat /tmp/healthy` inside the container.

---

### Step 8: Graceful Shutdown and preStop Hooks

Configure graceful shutdown to allow in-flight requests to complete before termination:

```bash
envsubst '$STUDENT_NAME' < graceful-app.yaml | kubectl apply -f -

kubectl get pods -l app=graceful-app
kubectl get pod -l app=graceful-app -o jsonpath='{.items[0].spec.terminationGracePeriodSeconds}'
```

> ✅ **Checkpoint:** `terminationGracePeriodSeconds` is 45 (default is 30). The preStop hook runs `sleep 10; nginx -s quit` to drain connections before stopping.

> **Why it matters:** Without a preStop hook, `SIGTERM` is sent immediately. If the pod is still in Service endpoints, new requests may arrive during shutdown.

---

## Step 9: Clean Up

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace probes-lab-$STUDENT_NAME

# Verify cleanup
kubectl get namespace probes-lab-$STUDENT_NAME
```

> ✅ **Expected:** `Error from server (NotFound): namespaces "probes-lab-<usernumber>" not found`

---

## Key Takeaways

- **No Probes = No Protection:** Without probes, broken pods continue receiving traffic silently
- **Liveness:** Detects deadlocked or stuck containers and triggers restarts
- **Readiness:** Controls traffic routing — only healthy pods serve requests
- **Startup:** Protects slow-starting containers from premature liveness kills
- **Tuning:** Balance detection speed against probe overhead and false positives
- **TCP Probes:** Check port connectivity for non-HTTP services
- **Exec Probes:** Run custom health check commands inside containers
- **Graceful Shutdown:** Use `preStop` hooks and `terminationGracePeriodSeconds` to drain connections

---

*Lab 10 Complete — Up Next: Lab 11 — Deployment Strategies*
