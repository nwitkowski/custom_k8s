# Lab 11: Deployment Strategies
### Rolling Updates, Blue-Green, Canary and Disruption Budgets
**Intermediate Kubernetes — Module 11 of 13**

---

## Lab Overview

### Objectives

- Perform rolling updates and rollbacks
- Implement blue-green and canary deployment patterns
- Configure Pod Disruption Budgets
- Detect stuck rollouts with progress deadlines

### Prerequisites

- kubectl installed and configured
- Access to a Kubernetes cluster (EKS)
- Completion of Lab 1 with `kubectl` and cluster access configured

> **Duration:** ~45 minutes

---

## Step 1: Deploy v1 of the Application

```bash
cd ~/environment/custom_k8s/labs/lab-11
export STUDENT_NAME=<usernumber>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
```

> ⚠️ **Important:** Your `$STUDENT_NAME` ensures your resources don't conflict with other students.

```bash
kubectl create namespace deploy-lab-$STUDENT_NAME

kubectl create configmap app-v1-page \
  --from-literal=index.html='<h1 style="color:blue">Application v1</h1><p>Version: 1.0.0</p>' \
  -n deploy-lab-$STUDENT_NAME
```

Review `app-deploy-v1.yaml` — it creates a Deployment with rolling update strategy, mounting a ConfigMap for the page content.

Apply and expose:

```bash
envsubst '$STUDENT_NAME' < app-deploy-v1.yaml | kubectl apply -f -

kubectl expose deployment webapp \
  --port=80 --target-port=80 \
  --name=webapp-svc \
  -n deploy-lab-$STUDENT_NAME

kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp
```

Verify v1 is serving traffic:

```bash
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-svc
```

> ✅ **Checkpoint:** All pods should be Running. The curl response should show **Application v1**.

---

## Step 2: Perform a Rolling Update to v2

```bash
kubectl create configmap app-v2-page \
  --from-literal=index.html='<h1 style="color:green">Application v2</h1><p>Version: 2.0.0</p>' \
  -n deploy-lab-$STUDENT_NAME

kubectl set image deployment/webapp nginx=nginx:1.25 \
  -n deploy-lab-$STUDENT_NAME

kubectl patch deployment webapp -n deploy-lab-$STUDENT_NAME --type=json \
  -p='[{"op":"replace",
  "path":"/spec/template/spec/volumes/0/configMap/name",
  "value":"app-v2-page"}]'
```

---

## Step 3: Monitor the Rolling Update

```bash
kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME

kubectl rollout history deployment/webapp -n deploy-lab-$STUDENT_NAME
```

Verify v2 is serving:

```bash
kubectl run curl-test2 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-svc

kubectl get replicasets -n deploy-lab-$STUDENT_NAME -l app=webapp
```

> ✅ The curl response should show **Application v2**. The old ReplicaSet should have 0 replicas.

---

## Step 4: Rollback to v1

```bash
kubectl rollout undo deployment/webapp --to-revision=1 -n deploy-lab-$STUDENT_NAME

kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME

kubectl run curl-test3 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-svc

kubectl rollout history deployment/webapp -n deploy-lab-$STUDENT_NAME
```

> ✅ The curl response should show **Application v1** again, served by the original `nginx:1.24` image. Step 2 produced two revisions (the image change, then the page change), so a plain `kubectl rollout undo` would only revert the last one — `--to-revision=1` returns the Deployment fully to v1.

---

## Step 5: Implement Blue-Green Deployment

Review the three manifests: `blue-deploy.yaml` (blue Deployment), `green-deploy.yaml` (green Deployment), and `bg-service.yaml` (Service initially pointing to blue).

Apply and switch traffic:

```bash
envsubst '$STUDENT_NAME' < blue-deploy.yaml | kubectl apply -f -
envsubst '$STUDENT_NAME' < green-deploy.yaml | kubectl apply -f -
envsubst '$STUDENT_NAME' < bg-service.yaml | kubectl apply -f -

kubectl run bg-test1 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-bg-svc

# Switch traffic to green
kubectl patch service webapp-bg-svc -n deploy-lab-$STUDENT_NAME \
  -p '{"spec":{"selector":{"version":"green"}}}'

kubectl run bg-test2 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-bg-svc
```

> ✅ First curl shows **BLUE**, second curl shows **GREEN**. The switch is instantaneous.

---

## Step 6: Implement Canary Deployment

Review the three manifests: `canary-stable.yaml` (stable Deployment, 2 replicas), `canary-new.yaml` (canary Deployment, 1 replica), and `canary-service.yaml` (Service selecting both via the shared `app` label).

```bash
envsubst '$STUDENT_NAME' < canary-stable.yaml | kubectl apply -f -
envsubst '$STUDENT_NAME' < canary-new.yaml | kubectl apply -f -
envsubst '$STUDENT_NAME' < canary-service.yaml | kubectl apply -f -
kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp-canary --show-labels
```

> ✅ 3 pods total -- 2 with `track=stable` and 1 with `track=canary` (~33% canary traffic).

---

## Step 7: Verify Canary Traffic Distribution

```bash
kubectl run traffic-test --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- sh -c '
  STABLE=0; CANARY=0
  for i in $(seq 1 20); do
    RESPONSE=$(curl -s webapp-canary-svc)
    if echo "$RESPONSE" | grep -q "STABLE"; then
      STABLE=$((STABLE+1))
    else
      CANARY=$((CANARY+1))
    fi
  done
  echo "Stable: $STABLE / Canary: $CANARY out of 20 requests"
'
```

> ✅ Approximately `Stable: 14 / Canary: 6` (roughly 67/33 split). Results will vary.

---

## Step 8: Pod Disruption Budgets

Review `pdb.yaml` — it creates a PodDisruptionBudget requiring at least 2 webapp pods available.

```bash
envsubst '$STUDENT_NAME' < pdb.yaml | kubectl apply -f -
kubectl get pdb -n deploy-lab-$STUDENT_NAME
```

Test with a dry-run drain:

```bash
kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp -o wide

# Get a node name from the output above, then dry-run drain
NODE_NAME=$(kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp \
  -o jsonpath='{.items[0].spec.nodeName}')

# Dry-run only -- NEVER drain without --dry-run in a shared cluster
kubectl drain $NODE_NAME --ignore-daemonsets \
  --delete-emptydir-data --dry-run=client
```

---

## Step 9: Configure Progress Deadline

Trigger a stuck rollout with a non-existent image:

```bash
kubectl patch deployment webapp -n deploy-lab-$STUDENT_NAME \
  -p '{"spec":{"progressDeadlineSeconds":60}}'

kubectl set image deployment/webapp nginx=nginx:nonexistent-tag \
  -n deploy-lab-$STUDENT_NAME

# Will report "exceeded its progress deadline" after 60s
kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME --timeout=90s
```

Recover:

```bash
kubectl rollout undo deployment/webapp -n deploy-lab-$STUDENT_NAME
kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME
```

> ✅ After rollback, all pods should be Running and Ready.

---

## Step 10: Clean Up

```bash
kubectl delete namespace deploy-lab-$STUDENT_NAME
```

---

## Key Takeaways

- **Rolling Updates** -- gradual replacement with `maxSurge`/`maxUnavailable` control
- **Blue-Green** -- instant traffic switch via service selector, requires double resources
- **Canary** -- gradual traffic shift using replica ratios
- **Pod Disruption Budgets** -- protects availability during voluntary disruptions
- **Progress Deadline** -- detects stuck rollouts automatically

---

*Lab 11 Complete — Up Next: Lab 12 — Helm and Templating*
