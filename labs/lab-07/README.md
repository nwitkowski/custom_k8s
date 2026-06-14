# Lab 7: RBAC, Security, and IRSA
### Pod Security Standards, SecurityContexts, and IAM Roles for Service Accounts
**Intermediate Kubernetes — Module 7 of 13**

---

## Lab Overview

### Objectives

- Explore existing ClusterRoles and bindings
- Create Roles, RoleBindings, and ServiceAccounts
- Apply Pod Security Standards and SecurityContexts
- Test RBAC permission boundaries
- *Optional:* Annotate ServiceAccounts with IAM roles (IRSA) and verify pod-level AWS access

### Prerequisites

- Completion of Lab 1 with `kubectl` and cluster access configured
- kubectl with cluster-admin access on a running EKS cluster

> **Duration:** ~45-55 minutes (core), 60+ with IRSA
>
> **Note:** Steps 9-11 (IRSA) are optional stretch goals. They require AWS-specific setup that may not work for all students.

---

## Environment Setup

```bash
cd ~/environment/custom_k8s/labs/lab-07
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
```

---

## Step 1: Explore Existing ClusterRoles

Create a namespace and examine the built-in ClusterRoles:

```bash
kubectl create namespace lab07-$STUDENT_NAME

kubectl get clusterroles | head -20

# Examine key built-in ClusterRoles
kubectl describe clusterrole admin
kubectl describe clusterrole edit
kubectl describe clusterrole view
```

---

## Step 2: Create a Namespace-Scoped Role and Bind It

Create a Role that allows read-only access to pods:

<!-- Creates a Role granting get/list/watch on pods and pods/log -->

Apply the manifest and create a ServiceAccount:

```bash
envsubst '$STUDENT_NAME' < pod-reader-role.yaml | kubectl apply -f -
kubectl create serviceaccount pod-viewer -n lab07-$STUDENT_NAME
```

<!-- Creates a RoleBinding connecting the pod-viewer SA to the pod-reader Role -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < pod-reader-binding.yaml | kubectl apply -f -
```

---

## Step 3: Test Permissions with kubectl auth can-i

```bash
kubectl auth can-i --list -n lab07-$STUDENT_NAME \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:pod-viewer
```

> ✅ **Checkpoint:** Output shows `get`, `list`, `watch` on `pods` and `get` on `pods/log` -- nothing else.

---

## Step 4: Deploy a Pod Using the ServiceAccount

<!-- Creates a pod running kubectl with the pod-viewer ServiceAccount -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < rbac-test-pod.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/rbac-test -n lab07-$STUDENT_NAME --timeout=60s

# This should SUCCEED
kubectl exec rbac-test -n lab07-$STUDENT_NAME -- kubectl get pods -n lab07-$STUDENT_NAME

# This should FAIL with Forbidden
kubectl exec rbac-test -n lab07-$STUDENT_NAME -- kubectl create deployment \
  test --image=nginx -n lab07-$STUDENT_NAME
```

> ✅ **Checkpoint:** `get pods` succeeds; `create deployment` fails with Forbidden.

---

## Step 5: Create a ClusterRole for Cross-Namespace Access

<!-- Creates a ClusterRole granting read access to pods, services, deployments, and replicasets -->

Apply the manifest and create a ServiceAccount:

```bash
envsubst '$STUDENT_NAME' < cluster-reader-role.yaml | kubectl apply -f -
kubectl create serviceaccount cluster-viewer -n lab07-$STUDENT_NAME
```

Bind it with a ClusterRoleBinding:

<!-- Creates a ClusterRoleBinding connecting the cluster-viewer SA to the ClusterRole -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < cluster-reader-binding.yaml | kubectl apply -f -

# Test cross-namespace read (should be YES)
kubectl auth can-i list pods -n kube-system \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:cluster-viewer

# Test delete (should be NO)
kubectl auth can-i delete pods -n kube-system \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:cluster-viewer
```

> ✅ **Checkpoint:** `list pods` returns `yes` in any namespace; `delete pods` returns `no`.

---

## Step 6: Apply Pod Security Standards

Create a namespace with the **restricted** Pod Security Standard:

```bash
kubectl create namespace lab07-restricted-$STUDENT_NAME

kubectl label namespace lab07-restricted-$STUDENT_NAME \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest
```

---

## Step 7: Test Pod Security -- Violations

Try deploying pods that violate the restricted profile:

<!-- Creates a pod with privileged: true (should be rejected) -->

<!-- Creates a pod running as root user (should be rejected) -->

Apply both manifests:

```bash
# Both should FAIL under the restricted profile
envsubst '$STUDENT_NAME' < privileged-pod.yaml | kubectl apply -f -
envsubst '$STUDENT_NAME' < root-pod.yaml | kubectl apply -f -
```

> ✅ **Checkpoint:** Both pods are blocked. The privileged pod is rejected by two independent admission layers — expect a Pod Security error (`violates PodSecurity "restricted:latest"`) or the cluster Kyverno policy message (`Privileged containers are not allowed.`). The root pod fails the `runAsNonRoot` check. Either message means the guardrails are working.

---

## Step 8: Deploy a Compliant Secure Pod

<!-- Creates a pod that meets the restricted security profile (non-root, read-only FS, no capabilities) -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < secure-pod.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/secure-app \
  -n lab07-restricted-$STUDENT_NAME --timeout=60s

# Verify security settings inside the pod
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- id
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- touch /test-file
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- touch /tmp/test-file
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- \
  cat /proc/1/status | grep -i cap
```

> ✅ **Checkpoint:**
> - `id` --> `uid=1000 gid=1000 groups=1000`
> - `touch /test-file` --> **Read-only file system** error
> - `touch /tmp/test-file` --> succeeds
> - `CapEff` --> `0000000000000000` (no capabilities)

---

---

## Optional Stretch Goals

> These exercises cover additional topics from the presentation. Complete them if you finish the core lab early.

## Part 3: IRSA -- IAM Roles for Service Accounts

### Step 9: Create an IRSA-Annotated ServiceAccount

The cluster includes a pre-provisioned IAM role (`platform-lab-irsa-s3-reader`) shared by all students. Its trust policy allows any `s3-reader-*` ServiceAccount in any `lab07-irsa-*` namespace to assume it, and it grants read-only access to the demo S3 bucket.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/platform-lab-irsa-s3-reader"
echo "Role ARN: $ROLE_ARN"
```

```bash
kubectl create namespace lab07-irsa-$STUDENT_NAME

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader-$STUDENT_NAME
  namespace: lab07-irsa-$STUDENT_NAME
  annotations:
    eks.amazonaws.com/role-arn: "${ROLE_ARN}"
EOF
```

---

### Step 10: Deploy and Test an IRSA Pod

<!-- Creates a pod with the IRSA-annotated ServiceAccount to test S3 access -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < irsa-test-pod.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready \
  pod/irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME --timeout=60s

# Test S3 read access
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- aws s3 ls s3://platform-lab-irsa-demo/

kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- aws s3 cp s3://platform-lab-irsa-demo/test-file.txt -

# Test S3 write (should be denied)
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- bash -c "echo test | aws s3 cp - \
    s3://platform-lab-irsa-demo/unauthorized-$STUDENT_NAME.txt"
```

> ✅ **Checkpoint:** `s3 ls` and `s3 cp` (read) succeed. Write returns **AccessDenied**.

---

### Step 11: Inspect the IRSA Credential Chain

```bash
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- env | grep AWS

kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- aws sts get-caller-identity
```

> ✅ **Checkpoint:** `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` are injected. The STS identity ARN contains `assumed-role/platform-lab-irsa-s3-reader`.

> ⚠️ **Troubleshooting:** If `sts get-caller-identity` shows the EC2 instance role, IRSA is not working. Verify the `eks.amazonaws.com/role-arn` annotation and OIDC provider configuration.

---

## Step 12: Clean Up

```bash
kubectl delete clusterrolebinding cluster-pod-reader-binding-$STUDENT_NAME
kubectl delete clusterrole cluster-pod-reader-$STUDENT_NAME

kubectl delete namespace lab07-$STUDENT_NAME
kubectl delete namespace lab07-restricted-$STUDENT_NAME
kubectl delete namespace lab07-irsa-$STUDENT_NAME
```

---

## Summary

- RBAC uses an additive model -- permissions are granted, never denied
- Roles are namespace-scoped; ClusterRoles are cluster-scoped; bind them with RoleBindings or ClusterRoleBindings
- Pod Security Standards (restricted, baseline, privileged) enforce security profiles at the namespace level
- SecurityContext settings (`runAsNonRoot`, `readOnlyRootFilesystem`, `drop: ALL`) provide defense-in-depth
- IRSA provides pod-level IAM identities via projected service-account tokens -- no long-lived AWS keys needed

---

*Lab 7 Complete — Up Next: Lab 8 — Network Policies*
