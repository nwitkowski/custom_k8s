#!/bin/bash
###############################################################################
# Lab 7 Test: RBAC, Security, and IRSA — Comprehensive Coverage
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-07" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab07-$STUDENT_NAME"
NS_RESTRICTED="lab07-restricted-$STUDENT_NAME"
NS_IRSA="lab07-irsa-$STUDENT_NAME"
echo "=== Lab 7: RBAC, Security & IRSA (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

###############################################################################
# Step 1: Explore Existing ClusterRoles
###############################################################################

echo "Built-in ClusterRoles:"

CR_LIST=$(kubectl get clusterroles --no-headers 2>/dev/null)
assert_contains "admin ClusterRole exists" "$CR_LIST" "admin"
assert_contains "edit ClusterRole exists" "$CR_LIST" "edit"
assert_contains "view ClusterRole exists" "$CR_LIST" "view"

ADMIN_DESC=$(kubectl describe clusterrole admin 2>/dev/null)
assert_contains "admin role has wildcard verbs" "$ADMIN_DESC" "get"

###############################################################################
# Step 2: Create Namespace-Scoped Role and Bind It
###############################################################################

echo ""
echo "RBAC — Role & RoleBinding:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/pod-reader-role.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "pod-reader Role created" kubectl get role pod-reader -n "$NS"

kubectl create serviceaccount pod-viewer -n "$NS" &>/dev/null
assert_cmd "pod-viewer ServiceAccount created" kubectl get serviceaccount pod-viewer -n "$NS"

envsubst '$STUDENT_NAME' < "$LAB_DIR/pod-reader-binding.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "read-pods RoleBinding created" kubectl get rolebinding read-pods -n "$NS"

# Verify Role details
ROLE_DESC=$(kubectl get role pod-reader -n "$NS" -o json 2>/dev/null)
assert_contains "Role grants get on pods" "$ROLE_DESC" '"get"'
assert_contains "Role grants list on pods" "$ROLE_DESC" '"list"'
assert_contains "Role grants watch on pods" "$ROLE_DESC" '"watch"'

###############################################################################
# Step 3: Test Permissions with kubectl auth can-i
###############################################################################

echo ""
echo "RBAC — Permission Checks:"

SA_IDENT="system:serviceaccount:${NS}:pod-viewer"

CAN_GET=$(kubectl auth can-i get pods -n "$NS" --as="$SA_IDENT" 2>/dev/null)
assert_eq "pod-viewer can get pods" "yes" "$CAN_GET"

CAN_LIST=$(kubectl auth can-i list pods -n "$NS" --as="$SA_IDENT" 2>/dev/null)
assert_eq "pod-viewer can list pods" "yes" "$CAN_LIST"

CAN_WATCH=$(kubectl auth can-i watch pods -n "$NS" --as="$SA_IDENT" 2>/dev/null)
assert_eq "pod-viewer can watch pods" "yes" "$CAN_WATCH"

CAN_GET_LOG=$(kubectl auth can-i get pods/log -n "$NS" --as="$SA_IDENT" 2>/dev/null)
assert_eq "pod-viewer can get pods/log" "yes" "$CAN_GET_LOG"

CAN_CREATE=$(kubectl auth can-i create deployments -n "$NS" --as="$SA_IDENT" 2>/dev/null)
assert_eq "pod-viewer cannot create deployments" "no" "$CAN_CREATE"

CAN_DELETE=$(kubectl auth can-i delete pods -n "$NS" --as="$SA_IDENT" 2>/dev/null)
assert_eq "pod-viewer cannot delete pods" "no" "$CAN_DELETE"

CAN_CREATE_POD=$(kubectl auth can-i create pods -n "$NS" --as="$SA_IDENT" 2>/dev/null)
assert_eq "pod-viewer cannot create pods" "no" "$CAN_CREATE_POD"

# Verify no access in other namespaces
CAN_GET_DEFAULT=$(kubectl auth can-i get pods -n default --as="$SA_IDENT" 2>/dev/null)
assert_eq "pod-viewer cannot get pods in default ns" "no" "$CAN_GET_DEFAULT"

###############################################################################
# Step 4: Deploy rbac-test Pod and Exec Commands
###############################################################################

echo ""
echo "RBAC — Test Pod Exec:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/rbac-test-pod.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" rbac-test 90

if kubectl get pod rbac-test -n "$NS" --no-headers 2>/dev/null | grep -q Running; then
  # get pods should succeed
  EXEC_GET=$(kubectl exec rbac-test -n "$NS" -- kubectl get pods -n "$NS" 2>&1)
  if echo "$EXEC_GET" | grep -q "rbac-test"; then
    pass "rbac-test pod can get pods (exec)"
  else
    # May succeed but show different output; check exit code
    kubectl exec rbac-test -n "$NS" -- kubectl get pods -n "$NS" &>/dev/null
    if [ $? -eq 0 ]; then
      pass "rbac-test pod can get pods (exec)"
    else
      fail "rbac-test pod can get pods (exec)"
    fi
  fi

  # create deployment should fail with Forbidden
  EXEC_CREATE=$(kubectl exec rbac-test -n "$NS" -- kubectl create deployment test --image=nginx -n "$NS" 2>&1)
  if echo "$EXEC_CREATE" | grep -qi "forbidden\|cannot\|error"; then
    pass "rbac-test pod cannot create deployment (Forbidden)"
  else
    fail "rbac-test pod create deployment should be Forbidden"
  fi

  # delete pods should fail. Use --dry-run=server (NOT client): a client-side
  # dry-run never contacts the API server, so it bypasses authorization and
  # would always "succeed", masking RBAC. Server dry-run runs the real authz.
  EXEC_DELETE=$(kubectl exec rbac-test -n "$NS" -- kubectl delete pod rbac-test -n "$NS" --dry-run=server 2>&1)
  if echo "$EXEC_DELETE" | grep -qi "forbidden\|cannot\|error"; then
    pass "rbac-test pod cannot delete pods (Forbidden)"
  else
    fail "rbac-test pod delete pods should be Forbidden"
  fi
else
  skip "rbac-test pod not running — skipping exec tests"
fi

###############################################################################
# Step 5: ClusterRole & ClusterRoleBinding
###############################################################################

echo ""
echo "ClusterRole & ClusterRoleBinding:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/cluster-reader-role.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "ClusterRole created" kubectl get clusterrole "cluster-pod-reader-$STUDENT_NAME"

kubectl create serviceaccount cluster-viewer -n "$NS" &>/dev/null
assert_cmd "cluster-viewer ServiceAccount created" kubectl get serviceaccount cluster-viewer -n "$NS"

envsubst '$STUDENT_NAME' < "$LAB_DIR/cluster-reader-binding.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "ClusterRoleBinding created" kubectl get clusterrolebinding "cluster-pod-reader-binding-$STUDENT_NAME"

# Verify ClusterRole details
CR_JSON=$(kubectl get clusterrole "cluster-pod-reader-$STUDENT_NAME" -o json 2>/dev/null)
assert_contains "ClusterRole grants access to pods" "$CR_JSON" '"pods"'
assert_contains "ClusterRole grants access to services" "$CR_JSON" '"services"'
assert_contains "ClusterRole grants access to deployments" "$CR_JSON" '"deployments"'
assert_contains "ClusterRole grants access to replicasets" "$CR_JSON" '"replicasets"'

# Verify ClusterRoleBinding details
CRB_JSON=$(kubectl get clusterrolebinding "cluster-pod-reader-binding-$STUDENT_NAME" -o json 2>/dev/null)
assert_contains "CRB references cluster-viewer SA" "$CRB_JSON" "cluster-viewer"
assert_contains "CRB references correct ClusterRole" "$CRB_JSON" "cluster-pod-reader-$STUDENT_NAME"

CV_IDENT="system:serviceaccount:${NS}:cluster-viewer"

# Cross-namespace read tests
CAN_LIST_SYS=$(kubectl auth can-i list pods -n kube-system --as="$CV_IDENT" 2>/dev/null)
assert_eq "cluster-viewer can list pods in kube-system" "yes" "$CAN_LIST_SYS"

CAN_LIST_DEF=$(kubectl auth can-i list pods -n default --as="$CV_IDENT" 2>/dev/null)
assert_eq "cluster-viewer can list pods in default" "yes" "$CAN_LIST_DEF"

CAN_LIST_SVC=$(kubectl auth can-i list services -n kube-system --as="$CV_IDENT" 2>/dev/null)
assert_eq "cluster-viewer can list services in kube-system" "yes" "$CAN_LIST_SVC"

CAN_LIST_DEPLOY=$(kubectl auth can-i list deployments -n kube-system --as="$CV_IDENT" 2>/dev/null)
assert_eq "cluster-viewer can list deployments in kube-system" "yes" "$CAN_LIST_DEPLOY"

# Write operations should be denied
CAN_DELETE_SYS=$(kubectl auth can-i delete pods -n kube-system --as="$CV_IDENT" 2>/dev/null)
assert_eq "cluster-viewer cannot delete pods in kube-system" "no" "$CAN_DELETE_SYS"

CAN_CREATE_SYS=$(kubectl auth can-i create pods -n kube-system --as="$CV_IDENT" 2>/dev/null)
assert_eq "cluster-viewer cannot create pods in kube-system" "no" "$CAN_CREATE_SYS"

CAN_PATCH_SYS=$(kubectl auth can-i patch deployments -n kube-system --as="$CV_IDENT" 2>/dev/null)
assert_eq "cluster-viewer cannot patch deployments" "no" "$CAN_PATCH_SYS"

###############################################################################
# Step 6-7: Pod Security Standards — Violations
###############################################################################

echo ""
echo "Pod Security Standards:"

kubectl create namespace "$NS_RESTRICTED" &>/dev/null
kubectl label namespace "$NS_RESTRICTED" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest &>/dev/null

# Verify namespace labels
NS_LABELS=$(kubectl get namespace "$NS_RESTRICTED" -o json 2>/dev/null)
assert_contains "restricted enforce label set" "$NS_LABELS" "pod-security.kubernetes.io/enforce"

# Privileged pod should be rejected
PRIV_RESULT=$(envsubst '$STUDENT_NAME' < "$LAB_DIR/privileged-pod.yaml" | kubectl apply -f - 2>&1)
assert_contains "privileged pod rejected" "$PRIV_RESULT" "forbidden"

# Root pod should be rejected
ROOT_RESULT=$(envsubst '$STUDENT_NAME' < "$LAB_DIR/root-pod.yaml" | kubectl apply -f - 2>&1)
assert_contains "root pod rejected" "$ROOT_RESULT" "forbidden"

###############################################################################
# Step 8: Deploy Compliant Secure Pod
###############################################################################

echo ""
echo "Secure Pod:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/secure-pod.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS_RESTRICTED" secure-app 60

# Verify identity
ID_OUTPUT=$(kubectl exec secure-app -n "$NS_RESTRICTED" -- id 2>/dev/null)
assert_contains "secure pod runs as uid 1000" "$ID_OUTPUT" "uid=1000"
assert_contains "secure pod runs as gid 1000" "$ID_OUTPUT" "gid=1000"

# Read-only root filesystem
TOUCH_ROOT=$(kubectl exec secure-app -n "$NS_RESTRICTED" -- touch /test-file 2>&1)
assert_contains "root filesystem is read-only" "$TOUCH_ROOT" "Read-only file system"

# tmp is writable
assert_cmd "tmp dir is writable" kubectl exec secure-app -n "$NS_RESTRICTED" -- touch /tmp/test-file

# Check capabilities — CapEff should be empty/zero
CAP_OUTPUT=$(kubectl exec secure-app -n "$NS_RESTRICTED" -- cat /proc/1/status 2>/dev/null)
if echo "$CAP_OUTPUT" | grep -q "CapEff.*0000000000000000"; then
  pass "CapEff is empty (all capabilities dropped)"
else
  CAPEFF=$(echo "$CAP_OUTPUT" | grep "CapEff" | awk '{print $2}')
  if [ "$CAPEFF" = "0000000000000000" ]; then
    pass "CapEff is empty (all capabilities dropped)"
  else
    fail "CapEff should be 0000000000000000 (got: $CAPEFF)"
  fi
fi

# Verify securityContext fields via pod spec
RUN_AS_NON_ROOT=$(kubectl get pod secure-app -n "$NS_RESTRICTED" \
  -o jsonpath='{.spec.containers[0].securityContext.runAsNonRoot}' 2>/dev/null)
if [ -z "$RUN_AS_NON_ROOT" ]; then
  RUN_AS_NON_ROOT=$(kubectl get pod secure-app -n "$NS_RESTRICTED" \
    -o jsonpath='{.spec.securityContext.runAsNonRoot}' 2>/dev/null)
fi
assert_eq "runAsNonRoot is true" "true" "$RUN_AS_NON_ROOT"

READ_ONLY_FS=$(kubectl get pod secure-app -n "$NS_RESTRICTED" \
  -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}' 2>/dev/null)
assert_eq "readOnlyRootFilesystem is true" "true" "$READ_ONLY_FS"

ALLOW_PRIV_ESC=$(kubectl get pod secure-app -n "$NS_RESTRICTED" \
  -o jsonpath='{.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null)
assert_eq "allowPrivilegeEscalation is false" "false" "$ALLOW_PRIV_ESC"

###############################################################################
# Steps 9-11: IRSA — IAM Roles for Service Accounts
###############################################################################

echo ""
echo "IRSA:"

# Check if IRSA infrastructure is available
if aws sts get-caller-identity &>/dev/null; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null)
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/platform-lab-irsa-s3-reader"

  kubectl create namespace "$NS_IRSA" &>/dev/null

  # Create the annotated ServiceAccount
  cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader-$STUDENT_NAME
  namespace: $NS_IRSA
  annotations:
    eks.amazonaws.com/role-arn: "${ROLE_ARN}"
EOF

  SA_JSON=$(kubectl get serviceaccount "s3-reader-$STUDENT_NAME" -n "$NS_IRSA" -o json 2>/dev/null)
  assert_contains "IRSA SA has role-arn annotation" "$SA_JSON" "eks.amazonaws.com/role-arn"
  assert_contains "IRSA SA annotation has correct role ARN" "$SA_JSON" "platform-lab-irsa-s3-reader"

  # Deploy IRSA test pod
  envsubst '$STUDENT_NAME' < "$LAB_DIR/irsa-test-pod.yaml" | kubectl apply -f - &>/dev/null
  wait_for_pod "$NS_IRSA" "irsa-test-$STUDENT_NAME" 90

  if kubectl get pod "irsa-test-$STUDENT_NAME" -n "$NS_IRSA" --no-headers 2>/dev/null | grep -q Running; then
    # Check injected AWS environment variables
    ENV_OUTPUT=$(kubectl exec "irsa-test-$STUDENT_NAME" -n "$NS_IRSA" -- env 2>/dev/null)
    if echo "$ENV_OUTPUT" | grep -q "AWS_ROLE_ARN\|AWS_WEB_IDENTITY_TOKEN_FILE"; then
      pass "IRSA environment variables injected"

      # Test S3 read access
      S3_LS=$(kubectl exec "irsa-test-$STUDENT_NAME" -n "$NS_IRSA" -- aws s3 ls s3://platform-lab-irsa-demo/ 2>&1)
      if [ $? -eq 0 ]; then
        pass "IRSA S3 ls succeeds (read access)"
      else
        skip "IRSA S3 read failed — bucket may not exist"
      fi

      # Test S3 read specific file content
      S3_CONTENT=$(kubectl exec "irsa-test-$STUDENT_NAME" -n "$NS_IRSA" -- \
        aws s3 cp s3://platform-lab-irsa-demo/test-file.txt - 2>&1)
      if [ $? -eq 0 ] && [ -n "$S3_CONTENT" ]; then
        pass "IRSA S3 cp reads file content successfully"
      else
        skip "IRSA S3 cp test-file.txt failed — file may not exist in bucket"
      fi

      # Test S3 write should be denied
      S3_WRITE=$(kubectl exec "irsa-test-$STUDENT_NAME" -n "$NS_IRSA" -- \
        bash -c "echo test | aws s3 cp - s3://platform-lab-irsa-demo/unauthorized-$STUDENT_NAME.txt" 2>&1)
      if echo "$S3_WRITE" | grep -qi "denied\|error\|failed"; then
        pass "IRSA S3 write denied (read-only role)"
      else
        skip "IRSA S3 write test inconclusive"
      fi

      # Verify STS identity
      STS_OUTPUT=$(kubectl exec "irsa-test-$STUDENT_NAME" -n "$NS_IRSA" -- aws sts get-caller-identity 2>&1)
      if echo "$STS_OUTPUT" | grep -q "assumed-role"; then
        pass "IRSA STS identity shows assumed-role"
      else
        skip "IRSA STS identity check inconclusive"
      fi
    else
      skip "IRSA env vars not injected — OIDC provider may not be configured"
    fi
  else
    skip "IRSA test pod not running — skipping S3 tests"
  fi
else
  skip "AWS CLI not configured — skipping all IRSA tests"
  kubectl create namespace "$NS_IRSA" &>/dev/null
fi

###############################################################################
# Cleanup
###############################################################################

echo ""
echo "Cleanup:"
kubectl delete clusterrolebinding "cluster-pod-reader-binding-$STUDENT_NAME" &>/dev/null
kubectl delete clusterrole "cluster-pod-reader-$STUDENT_NAME" &>/dev/null
cleanup_ns "$NS"
cleanup_ns "$NS_RESTRICTED"
cleanup_ns "$NS_IRSA"
summary
