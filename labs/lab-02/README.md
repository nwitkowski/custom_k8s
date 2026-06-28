# Lab 2: Configuring Autoscaling
### HPA, VPA, and Cluster Autoscaler in Practice
**Intermediate Kubernetes — Module 2 of 13**

---

## Lab Overview

### Objectives

- Verify metrics-server and configure a Horizontal Pod Autoscaler (HPA)
- Generate load and observe automatic scaling in real time
- Create an HPA with custom metrics using the v2 API
- Explore Vertical Pod Autoscaler (VPA) and Cluster Autoscaler behavior

### Prerequisites

- Completed Lab 1 with `kubectl` and cluster access configured
- metrics-server installed in the cluster

> ⏱ **Duration:** ~45 minutes

---

## Environment Setup

```bash
cd ~/environment/custom_k8s/labs/lab-02
export STUDENT_NAME=<usernumber>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `$STUDENT_NAME` ensures your resources don't conflict with others.

---

## Step 1: Verify Metrics Server

```bash
kubectl get pods -n kube-system | grep metrics-server
kubectl get apiservices | grep metrics
kubectl top nodes
```

> ⚠️ **Troubleshooting:** If metrics-server is not installed, run:
> ```bash
> kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
> kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s
> ```

---

## Step 2: Deploy a CPU-Intensive Application

```bash
kubectl create namespace lab02-$STUDENT_NAME
kubectl config set-context --current --namespace=lab02-$STUDENT_NAME
```

<!-- Creates a php-apache Deployment with CPU requests/limits for HPA testing -->
Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < php-apache-deployment.yaml | kubectl apply -f -
kubectl expose deployment php-apache --port=80 --target-port=80
kubectl get all -n lab02-$STUDENT_NAME
```

---

## Step 3: Create a Horizontal Pod Autoscaler

```bash
kubectl autoscale deployment php-apache \
  --cpu-percent=50 \
  --min=1 \
  --max=10 \
  -n lab02-$STUDENT_NAME

kubectl get hpa -n lab02-$STUDENT_NAME
kubectl describe hpa php-apache -n lab02-$STUDENT_NAME
```

> ✅ **Checkpoint:** The HPA should show `TARGETS: <current>/50%`, `MINPODS: 1`, `MAXPODS: 10`, `REPLICAS: 1`. The current value may show `<unknown>/50%` for 15-30 seconds while metrics are collected.

---

## Step 4: Generate Load

Run a load generator in a separate pod:

```bash
kubectl run load-generator \
  --image=busybox:1.36 \
  --restart=Never \
  -n lab02-$STUDENT_NAME \
  -- /bin/sh -c "while sleep 0.01; do wget -q -O- http://php-apache; done"
```

Verify the load generator is running:

```bash
kubectl get pod load-generator -n lab02-$STUDENT_NAME
kubectl logs load-generator -n lab02-$STUDENT_NAME --tail=5
```

> ✅ **Checkpoint:** The pod should be in `Running` state and logs should show the php-apache response (`OK!`).

> ⚠️ **Important:** Open a **second terminal** for the next step. Keep the load generator running.

---

## Step 5: Observe Horizontal Scaling

In your **second terminal**, watch the HPA and pods respond:

```bash
# Set your student name in the new terminal
export STUDENT_NAME=<usernumber>

# Watch HPA status (updates every 15 seconds)
kubectl get hpa php-apache -n lab02-$STUDENT_NAME --watch

# In another terminal, watch pods scale up
kubectl get pods -n lab02-$STUDENT_NAME --watch
```

> ✅ **Checkpoint:** Within 1-3 minutes, TARGETS should increase above 50% and REPLICAS should scale up (up to 10). Check HPA events with `kubectl describe hpa php-apache -n lab02-$STUDENT_NAME`.

---

## Step 6: Stop Load and Observe Scale-Down

```bash
kubectl delete pod load-generator -n lab02-$STUDENT_NAME

# Watch the HPA scale down (~5 minutes)
kubectl get hpa php-apache -n lab02-$STUDENT_NAME --watch
```

> ✅ **Checkpoint:** After approximately 5 minutes, REPLICAS should decrease back to 1. The default stabilization window is 5 minutes to prevent thrashing.

---

## Step 7: HPA with Custom Metrics (v2 API)

```bash
kubectl delete hpa php-apache -n lab02-$STUDENT_NAME
```

<!-- Creates HPA v2 with CPU and memory metrics plus custom scaling behavior -->
Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < hpa-v2.yaml | kubectl apply -f -
kubectl describe hpa php-apache-v2 -n lab02-$STUDENT_NAME
```

> ✅ **Checkpoint:** The HPA should show two metrics targets: `cpu: <current>/50%` and `memory: <current>/80%`.

---

## Step 8: Vertical Pod Autoscaler (VPA)

```bash
# Check for VPA CRDs
kubectl get crd | grep verticalpodautoscaler
```

> 📝 **Note:** VPA is optional. If the CRDs are not installed, review the manifest below but skip the apply step.

<!-- Creates a VPA in Off mode (recommendation only) for php-apache -->
Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < vpa.yaml | kubectl apply -f -
kubectl describe vpa php-apache-vpa -n lab02-$STUDENT_NAME
```

> ✅ **Checkpoint:** The VPA status should show recommendation levels: **lowerBound**, **target**, and **upperBound**.

> ⚠️ Do not use VPA in `Auto` mode with HPA on the same CPU/memory metrics — they will conflict.

---

## Step 9: Cluster Autoscaler Behavior

> ⚠️ **Instructor Demo:** In a shared cluster, only run this step when directed by the instructor.

<!-- Creates an inflate Deployment with 5 replicas to pressure cluster capacity -->
Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < inflate-deployment.yaml | kubectl apply -f -

# Watch pods - some should be Pending if cluster is at capacity
kubectl get pods -n lab02-$STUDENT_NAME -l app=inflate --watch
```

> ✅ **Checkpoint:** Some pods will show `Pending` with `FailedScheduling: insufficient cpu`. If Cluster Autoscaler is active, new nodes may join within 2-5 minutes.

---

## Part 2: Scheduling and Placement

Continue with **[Lab 2 (Part 2): Scheduling and Placement](../lab-02-scheduling/README.md)** — node affinity, pod affinity/anti-affinity, taints & tolerations, topology spread, and DaemonSets. It uses its own `sched-$STUDENT_NAME` namespace, so you can run it before or after the cleanup below.

---

## Step 10: Clean Up

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace lab02-$STUDENT_NAME
```

---

## Summary

- HPA scales pod count based on CPU, memory, or custom metrics
- Resource requests are mandatory for HPA to function
- The v2 API provides fine-grained control over scaling behavior
- VPA right-sizes resource requests; use Off mode to gather data first
- Cluster Autoscaler adds nodes when pods cannot be scheduled
- All three autoscalers work at different layers and complement each other

---

*Lab 2 Complete — Up Next: Lab 3 — Storage and StatefulSets*
