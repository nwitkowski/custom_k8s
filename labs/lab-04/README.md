# Lab 4: Services and Service Discovery
### ClusterIP, NodePort, Headless Services, and DNS-Based Discovery
**Intermediate Kubernetes — Module 4 of 13**

---

## Lab Overview

### Objectives

- Deploy a multi-tier application with backend and frontend Deployments
- Create ClusterIP and NodePort Services
- Test DNS-based service discovery and examine Endpoints/EndpointSlices
- Compare headless vs. ClusterIP Service DNS behavior

### Prerequisites

- Completion of Lab 1 with `kubectl` and cluster access configured

> **Duration:** ~30 minutes

---

## Environment Setup

```bash
cd ~/environment/custom_k8s/labs/lab-04
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `$STUDENT_NAME` ensures your resources don't conflict with others.

---

## Step 1: Deploy a Multi-Tier Application

```bash
kubectl create namespace lab04-$STUDENT_NAME
```

<!-- Creates backend Deployment (3 replicas of httpbin with readiness probe) -->
<!-- Creates frontend Deployment (2 replicas of nginx) -->
Apply the manifests:

```bash
envsubst '$STUDENT_NAME' < backend-deployment.yaml | kubectl apply -f -
envsubst '$STUDENT_NAME' < frontend-deployment.yaml | kubectl apply -f -
kubectl get pods -n lab04-$STUDENT_NAME -o wide
```

> ✅ **Checkpoint:** You should have 5 pods running -- 3 backend and 2 frontend, all 1/1 Ready.

---

## Step 2: Create a ClusterIP Service for the Backend

<!-- Creates a ClusterIP Service selecting backend pods on port 80 -->
Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < backend-svc.yaml | kubectl apply -f -
kubectl get svc backend-svc -n lab04-$STUDENT_NAME
kubectl describe svc backend-svc -n lab04-$STUDENT_NAME
```

> ✅ **Checkpoint:** The `describe` output should list Endpoints matching all three backend pod IPs.

---

## Step 3: Test DNS-Based Service Discovery

```bash
FRONTEND_POD=$(kubectl get pod -n lab04-$STUDENT_NAME -l tier=web \
  -o jsonpath='{.items[0].metadata.name}')

# Install tools in the nginx container
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  apt-get update -qq && kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  apt-get install -y -qq curl dnsutils > /dev/null

# Test DNS resolution
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- nslookup backend-svc

# Curl the backend through the Service
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- curl -s backend-svc/ip
```

> ✅ **Checkpoint:** `nslookup` resolves `backend-svc` to its ClusterIP, and `curl` returns a JSON response from a backend pod. (The `/ip` endpoint reports the caller's source IP, so it stays the same across requests — the Service still load-balances each new connection across the backend pods behind that single ClusterIP.)

---

## Step 4: Examine DNS Records in Detail

```bash
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  nslookup backend-svc.lab04-$STUDENT_NAME.svc.cluster.local

kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- cat /etc/resolv.conf
```

DNS resolution formats:

| Format | Example |
|--------|---------|
| Short name (same namespace) | `backend-svc` |
| Namespace-qualified | `backend-svc.lab04-$STUDENT_NAME` |
| FQDN | `backend-svc.lab04-$STUDENT_NAME.svc.cluster.local` |

> ✅ **Checkpoint:** The `resolv.conf` should show search domains including your namespace.

---

## Step 5: Explore Endpoints and EndpointSlices

**Endpoints** are the original API — a single object listing all pod IPs for a Service. **EndpointSlices** are the newer replacement — they split the list into smaller chunks (max 100 per slice), which scales better for large Services and reduces API traffic when pods change.

```bash
# Endpoints: one object with all pod IPs in a flat list
kubectl get endpoints backend-svc -n lab04-$STUDENT_NAME
kubectl get endpoints backend-svc -n lab04-$STUDENT_NAME -o yaml | grep -A 2 "addresses:"

# EndpointSlices: sharded by addressType, with conditions per endpoint
kubectl get endpointslices -n lab04-$STUDENT_NAME \
  -l kubernetes.io/service-name=backend-svc
kubectl get endpointslices -n lab04-$STUDENT_NAME \
  -l kubernetes.io/service-name=backend-svc -o yaml | grep -A 5 "endpoints:"
```

> **Key difference:** Endpoints lists IPs only. EndpointSlices include per-pod `ready`/`serving`/`terminating` conditions, node name, and zone — giving kube-proxy richer routing information.

Scale the backend and watch Endpoints change:

```bash
# In one terminal, watch endpoints
kubectl get endpoints backend-svc -n lab04-$STUDENT_NAME -w

# In another terminal, scale down then back up
kubectl scale deployment backend -n lab04-$STUDENT_NAME --replicas=1
kubectl scale deployment backend -n lab04-$STUDENT_NAME --replicas=3
```

> ✅ **Checkpoint:** Endpoints update dynamically as pods scale. Both Endpoints and EndpointSlices reflect the same pod IPs, but EndpointSlices show additional metadata per endpoint.

---

## Step 6: Create a NodePort Service

<!-- Creates a NodePort Service for frontend pods on port 80 -->
Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < frontend-nodeport.yaml | kubectl apply -f -
kubectl get svc frontend-nodeport -n lab04-$STUDENT_NAME
NODE_PORT=$(kubectl get svc frontend-nodeport -n lab04-$STUDENT_NAME -o jsonpath='{.spec.ports[0].nodePort}')
echo "NodePort assigned: $NODE_PORT"
```

> ⚠️ **Note:** In EKS, node security groups may block NodePort traffic by default. NodePort is primarily for development -- production uses LoadBalancer or Ingress.

---

## Step 7: Create a Headless Service

<!-- Creates a headless Service (clusterIP: None) for direct pod IP resolution -->
Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < backend-headless.yaml | kubectl apply -f -
```

Compare DNS responses between normal and headless Services:

```bash
# ClusterIP Service - returns the virtual IP
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  dig backend-svc.lab04-$STUDENT_NAME.svc.cluster.local +short

# Headless Service - returns individual pod IPs
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  dig backend-headless.lab04-$STUDENT_NAME.svc.cluster.local +short
```

> ✅ **Checkpoint:** ClusterIP returns 1 virtual IP. Headless returns all pod IPs directly, letting the client choose which pod to connect to.

---

## Optional Stretch Goal: LoadBalancer Service

Expose the frontend through an AWS load balancer:

```bash
envsubst '$STUDENT_NAME' < frontend-lb.yaml | kubectl apply -f -

# Wait 2-3 minutes for AWS to provision the load balancer, then:
kubectl get svc frontend-lb -n lab04-$STUDENT_NAME
LB_HOST=$(kubectl get svc frontend-lb -n lab04-$STUDENT_NAME \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s --max-time 10 http://$LB_HOST | head -5
```

> ⚠️ **Each LoadBalancer Service provisions a real AWS load balancer (billed hourly).** Delete it as soon as you've tested it:

```bash
kubectl delete svc frontend-lb -n lab04-$STUDENT_NAME
```

---

## Step 8: Clean Up

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace lab04-$STUDENT_NAME
```

---

## Summary

| Service Type | Scope | Use Case |
|-------------|-------|----------|
| **ClusterIP** | Internal only | Service-to-service communication |
| **NodePort** | External via node IP | Development and testing |
| **Headless** | Internal, no VIP | StatefulSets, direct pod access |

- DNS is the primary discovery mechanism (short names within namespace, FQDN across namespaces)
- Endpoints track ready pod IPs dynamically as pods scale
- Always configure readiness probes so only healthy pods receive traffic

---

*Lab 4 Complete — Up Next: Lab 5 — ConfigMaps and Secrets*
