# Bonus Lab: Scheduling with Affinity and Anti-Affinity
### Node Affinity, Pod Affinity, Pod Anti-Affinity, and Taints/Tolerations
**Intermediate Kubernetes — Bonus Content**

---

## Lab Overview

### Objectives

- Use node affinity to schedule pods on specific nodes
- Use pod affinity to co-locate related pods
- Use pod anti-affinity to spread pods across nodes
- Apply taints and tolerations to control scheduling

### Prerequisites

- Lab 1 (cluster access configured)

> **Duration:** ~25 minutes

---

## Environment Setup

```bash
cd ~/environment/custom_k8s/labs/extras/scheduling-affinity
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
kubectl create namespace sched-$STUDENT_NAME
kubectl config set-context --current --namespace=sched-$STUDENT_NAME
```

---

## Step 1: Examine Node Labels

```bash
kubectl get nodes --show-labels
kubectl get nodes -o custom-columns=NAME:.metadata.name,ZONE:'.metadata.labels.topology\.kubernetes\.io/zone',INSTANCE:'.metadata.labels.node\.kubernetes\.io/instance-type'
```

> ✅ **Checkpoint:** You should see nodes with zone and instance-type labels.

---

## Step 2: Node Affinity — Required

This pod **must** run on a node in `us-east-2a` (adjust zone to match your cluster):

```bash
envsubst '$STUDENT_NAME' < node-affinity-required.yaml | kubectl apply -f -
kubectl get pod node-affinity-required -o wide
```

> ✅ **Checkpoint:** The pod is scheduled on a node in the specified zone.

Try an impossible match:

```bash
envsubst '$STUDENT_NAME' < node-affinity-nope.yaml | kubectl apply -f -
kubectl get pod node-affinity-nope
kubectl describe pod node-affinity-nope | tail -5
```

> ✅ **Checkpoint:** The pod stays `Pending` with `FailedScheduling` — no node matches the required label.

---

## Step 3: Node Affinity — Preferred

This pod **prefers** a specific zone but will schedule elsewhere if needed:

```bash
envsubst '$STUDENT_NAME' < node-affinity-preferred.yaml | kubectl apply -f -
kubectl get pod node-affinity-preferred -o wide
```

> ✅ **Checkpoint:** The pod runs — preferably in the preferred zone, but it won't stay Pending if no match exists.

---

## Step 4: Pod Affinity — Co-locate Pods

Deploy a cache pod, then a web pod that must run on the **same node** as the cache:

```bash
envsubst '$STUDENT_NAME' < cache-pod.yaml | kubectl apply -f -
envsubst '$STUDENT_NAME' < web-with-affinity.yaml | kubectl apply -f -
kubectl get pods -o wide
```

> ✅ **Checkpoint:** Both pods are on the same node.

---

## Step 5: Pod Anti-Affinity — Spread Across Nodes

Deploy a 3-replica Deployment where replicas **avoid** running on the same node:

```bash
envsubst '$STUDENT_NAME' < spread-deployment.yaml | kubectl apply -f -
kubectl get pods -l app=spread-app -o wide
```

> ✅ **Checkpoint:** Each replica is on a different node (if 3+ nodes available). If fewer nodes exist, some pods may be Pending.

---

## Step 6: Taints and Tolerations

> ⚠️ **Shared cluster:** Do NOT taint real nodes. This step uses `kubectl describe` to view existing taints only.

```bash
# View existing taints on nodes
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:'.spec.taints[*].key'

# Check for the control-plane taint
kubectl describe nodes | grep -A 2 "Taints:"
```

Deploy a pod that tolerates the `dedicated=monitoring` taint:

```bash
envsubst '$STUDENT_NAME' < toleration-pod.yaml | kubectl apply -f -
kubectl get pod toleration-demo -o yaml | grep -A 5 "tolerations:"
```

> ✅ **Checkpoint:** The pod's toleration section shows it can handle the `dedicated=monitoring` taint. On this cluster it schedules normally since no node has that taint — the toleration is simply ignored.

---

## Step 7: Topology Spread Constraints

Spread pods evenly across availability zones:

```bash
envsubst '$STUDENT_NAME' < topology-spread.yaml | kubectl apply -f -
kubectl get pods -l app=zone-spread -o wide
```

```bash
# Check distribution across zones — pods don't carry zone labels,
# so list the pods' nodes and map each node to its zone
kubectl get pods -l app=zone-spread \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
kubectl get nodes -L topology.kubernetes.io/zone
```

> ✅ **Checkpoint:** Pods are distributed across availability zones with a max skew of 1.

---

## Clean Up

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace sched-$STUDENT_NAME
```

---

## Summary

| Concept | Effect | Use Case |
|---------|--------|----------|
| **Node Affinity (required)** | Pod must match node labels | Pin to specific zone/instance type |
| **Node Affinity (preferred)** | Pod prefers matching nodes | Soft preference, won't block scheduling |
| **Pod Affinity** | Co-locate with other pods | Cache near app, reduce latency |
| **Pod Anti-Affinity** | Spread away from other pods | HA — replicas on different nodes |
| **Taints/Tolerations** | Nodes repel pods unless tolerated | Dedicated nodes for specific workloads |
| **Topology Spread** | Even distribution across zones | Zone-balanced deployments |

---

*Bonus Lab Complete*
