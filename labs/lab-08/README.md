# Lab 8: Network Policies
### Controlling Pod-to-Pod Communication with NetworkPolicy Resources
**Intermediate Kubernetes — Module 8 of 13**

---

## Lab Overview

### Objectives

- Deploy a three-tier application and verify default connectivity
- Apply a default-deny ingress NetworkPolicy
- Create targeted ingress policies per tier
- Debug a broken NetworkPolicy
- *Optional:* Apply egress deny-all and selective allow policies
- *Optional:* Use namespace selectors for cross-namespace access

### Prerequisites

- Completion of Lab 1 with `kubectl` and cluster access configured
- CNI with NetworkPolicy support (Calico or Cilium)

> **Duration:** ~30-40 minutes
>
> **Note:** Steps 9-10 are optional stretch goals for students who finish early.

---

## Environment Setup

```bash
cd ~/environment/custom_k8s/labs/lab-08
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
```

---

## Step 1: Deploy a Three-Tier Application

```bash
kubectl create namespace lab08-$STUDENT_NAME
```

### Deploy the Database Tier

<!-- Creates a database Pod and Service -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < database.yaml | kubectl apply -f -
```

### Deploy the Backend and Frontend Tiers

<!-- Creates backend and frontend Pods and Services -->

Apply the manifests:

```bash
envsubst '$STUDENT_NAME' < backend.yaml | kubectl apply -f -
envsubst '$STUDENT_NAME' < frontend.yaml | kubectl apply -f -

kubectl wait --for=condition=Ready pod --all -n lab08-$STUDENT_NAME --timeout=60s
kubectl get pods -n lab08-$STUDENT_NAME -o wide --show-labels
```

---

## Step 2: Verify Default Connectivity

Confirm all pods can communicate (all should succeed):

```bash
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:80

kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:80

kubectl exec database -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
```

---

## Step 3: Apply Default Deny-All Ingress Policy

<!-- Creates a NetworkPolicy that denies all ingress traffic in the namespace -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < deny-all-ingress.yaml | kubectl apply -f -
```

---

## Step 4: Verify Isolation

```bash
# All should FAIL / timeout
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:80
echo "Exit code: $?"

kubectl exec backend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:80
echo "Exit code: $?"

kubectl exec database -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
echo "Exit code: $?"
```

> ✅ **Checkpoint:** All curl commands timeout with a non-zero exit code.

---

## Step 5: Allow Frontend to Backend Communication

<!-- Creates a NetworkPolicy allowing ingress to backend from frontend on port 80 -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < allow-frontend-to-backend.yaml | kubectl apply -f -

# Frontend -> Backend (should now SUCCEED)
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:80

# Database -> Backend (should still FAIL)
kubectl exec database -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:80
```

> ✅ **Checkpoint:** Frontend to backend succeeds; database to backend times out.

---

## Step 6: Allow Backend to Database Communication

<!-- Creates a NetworkPolicy allowing ingress to database from backend on port 80 -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < allow-backend-to-database.yaml | kubectl apply -f -

# Backend -> Database (should now SUCCEED)
kubectl exec backend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:80

# Frontend -> Database (should still FAIL)
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:80
```

> ✅ **Checkpoint:** Backend to database succeeds; frontend to database times out.

---

## Step 7: Test the Complete Policy Set

```bash
echo "=== ALLOWED PATHS ==="
echo -n "Frontend -> Backend: "
kubectl exec frontend -n lab08-$STUDENT_NAME -- curl -s -o /dev/null \
  -w "%{http_code}" --max-time 3 \
  http://backend:80 2>/dev/null || echo "BLOCKED"

echo -n "Backend -> Database: "
kubectl exec backend -n lab08-$STUDENT_NAME -- curl -s -o /dev/null \
  -w "%{http_code}" --max-time 3 \
  http://database:80 2>/dev/null || echo "BLOCKED"

echo ""
echo "=== BLOCKED PATHS ==="
echo -n "Frontend -> Database: "
kubectl exec frontend -n lab08-$STUDENT_NAME -- curl -s -o /dev/null \
  -w "%{http_code}" --max-time 3 \
  http://database:80 2>/dev/null || echo "BLOCKED"

echo -n "Database -> Frontend: "
kubectl exec database -n lab08-$STUDENT_NAME -- curl -s -o /dev/null \
  -w "%{http_code}" --max-time 3 \
  http://frontend:80 2>/dev/null || echo "BLOCKED"

echo -n "Database -> Backend: "
kubectl exec database -n lab08-$STUDENT_NAME -- curl -s -o /dev/null \
  -w "%{http_code}" --max-time 3 \
  http://backend:80 2>/dev/null || echo "BLOCKED"
```

> ✅ **Checkpoint:** Frontend->Backend: 200, Backend->Database: 200, all others: BLOCKED.

---

## Step 8: Debug a Broken Policy

Apply this intentionally broken policy and find the bugs:

<!-- Creates a NetworkPolicy with two intentional bugs for debugging practice -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < broken-policy.yaml | kubectl apply -f -
kubectl run test-client --image=nginx:1.25 -n lab08-$STUDENT_NAME --rm -it \
  --restart=Never -- curl -s --max-time 3 \
  http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
```

> ⚠️ **Two bugs:** (1) `from.podSelector` matches `tier: frontend` (self-referencing) -- should be `from: []` to allow all sources. (2) Port is `8080` but frontend listens on `80`.

### Fix the Broken Policy

<!-- Creates the corrected NetworkPolicy (from: [] and port: 80) -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < fixed-policy.yaml | kubectl apply -f -
kubectl run test-client --image=nginx:1.25 \
  -n lab08-$STUDENT_NAME --rm -it --restart=Never -- \
  curl -s --max-time 3 \
  http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
```

> ✅ **Checkpoint:** The test client can now reach the frontend.

---

---

## Optional Stretch Goals

> These exercises cover additional topics from the presentation. Complete them if you finish the core lab early.

### Step 9: Egress Policies

Apply a default deny-all egress policy, then selectively allow DNS:

```bash
# Deny all outbound traffic
envsubst '$STUDENT_NAME' < deny-all-egress.yaml | kubectl apply -f -

# Verify — outbound requests should now fail
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:80
echo "Exit code: $?"
```

```bash
# Allow DNS resolution (UDP port 53)
envsubst '$STUDENT_NAME' < allow-dns-egress.yaml | kubectl apply -f -

kubectl describe networkpolicy allow-dns-egress -n lab08-$STUDENT_NAME
```

> ✅ **Checkpoint:** The deny-all-egress policy blocks all outbound traffic. The allow-dns-egress policy permits DNS resolution on port 53.

---

### Step 10: Namespace-Based Policy

Allow ingress from a monitoring namespace:

```bash
envsubst '$STUDENT_NAME' < allow-monitoring-ingress.yaml | kubectl apply -f -

kubectl describe networkpolicy allow-monitoring-ingress -n lab08-$STUDENT_NAME
```

> ✅ **Checkpoint:** The policy uses a `namespaceSelector` with `purpose: monitoring` to allow ingress on port 80 from pods in monitoring namespaces.

---

## Step 11: Clean Up

```bash
kubectl delete namespace lab08-$STUDENT_NAME
```

---

## Summary

- Kubernetes defaults to allowing all pod-to-pod communication -- NetworkPolicies add restrictions
- Start with a default deny-all policy, then selectively allow required traffic
- NetworkPolicies are additive -- multiple policies combine their allowed paths
- Use `podSelector` and labels to precisely control which pods can communicate
- **Egress policies** control outbound traffic -- always allow DNS (port 53) when restricting egress
- **Namespace selectors** enable cross-namespace communication rules (e.g., monitoring access)

---

*Lab 8 Complete — Up Next: Lab 9 — Observability*
