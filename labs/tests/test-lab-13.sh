#!/bin/bash
###############################################################################
# Lab 13 Test: CI/CD and GitOps with FluxCD
# Covers: Container build/tag, ECR repo creation (conditional), kubectl deploy,
#         ArgoCD Application CRD apply and sync, FluxCD HelmRepository,
#         HelmRelease apply, drift detection and reconciliation
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-13" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS_CICD="cicd-lab-$STUDENT_NAME"
NS_ARGOCD="argocd-lab-$STUDENT_NAME"
NS_FLUX="flux-lab-$STUDENT_NAME"
echo "=== Lab 13: CI/CD & GitOps (ns: $NS_CICD, $NS_FLUX) ==="
echo ""

# ─── Step 2: Build and tag a container image ────────────────────────────────

echo "Step 2 — Container Build:"
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init &>/dev/null
git config user.email "lab-test@example.com"
git config user.name "Lab Test"

cat > index.html <<'HEREDOC'
<html><body>
  <h1>CI/CD Demo Application</h1>
  <p>Build: __BUILD_SHA__</p>
  <p>Deployed: __DEPLOY_TIME__</p>
</body></html>
HEREDOC

cat > Dockerfile <<'HEREDOC'
FROM nginx:1.25-alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
HEREDOC

git add . && git commit -m "Initial application" &>/dev/null
GIT_SHA=$(git rev-parse --short HEAD)

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  # Inject build SHA into HTML
  sed "s/__BUILD_SHA__/$GIT_SHA/g; s/__DEPLOY_TIME__/$(date -u +%Y-%m-%dT%H:%M:%SZ)/g" \
    index.html > index.html.built
  mv index.html.built index.html

  docker build -t my-app:$GIT_SHA . &>/dev/null
  assert_cmd "image built with SHA tag $GIT_SHA" docker image inspect "my-app:$GIT_SHA"

  docker build -t my-app:latest . &>/dev/null
  assert_cmd "image built with latest tag" docker image inspect "my-app:latest"
else
  skip "docker not available or not running"
fi
cd - &>/dev/null

# ─── Step 3: Push to ECR (conditional) ──────────────────────────────────────

echo ""
echo "Step 3 — ECR Integration:"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -n "$AWS_ACCOUNT_ID" ]; then
  pass "AWS account accessible: $AWS_ACCOUNT_ID"
  # Cluster region: honor CLUSTER_REGION/AWS_REGION, else fall back to us-east-2.
  REGION="${CLUSTER_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}}"
  export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
  export ECR_REPO="cicd-lab-app-$STUDENT_NAME"

  # Test ECR login
  ECR_LOGIN=$(aws ecr get-login-password --region "$REGION" 2>/dev/null | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY" 2>&1 || true)
  if echo "$ECR_LOGIN" | grep -q "Login Succeeded"; then
    pass "ECR login succeeded"
    ECR_LOGGED_IN=true
  else
    skip "ECR login failed (docker may not be running)"
    ECR_LOGGED_IN=false
  fi

  # Create ECR repository (conditional)
  ECR_CREATE=$(aws ecr create-repository --repository-name "$ECR_REPO" \
    --region "$REGION" 2>&1 || true)
  if echo "$ECR_CREATE" | grep -q "repositoryUri\|RepositoryAlreadyExistsException"; then
    pass "ECR repository $ECR_REPO created or already exists"
  else
    skip "ECR repository creation failed"
  fi

  # Tag and push image to ECR (conditional on docker + ECR login)
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1 && [ "$ECR_LOGGED_IN" = "true" ]; then
    docker tag my-app:$GIT_SHA $ECR_REGISTRY/cicd-lab-app-$STUDENT_NAME:$GIT_SHA &>/dev/null 2>&1
    PUSH_RESULT=$(docker push $ECR_REGISTRY/cicd-lab-app-$STUDENT_NAME:$GIT_SHA 2>&1 || true)
    if echo "$PUSH_RESULT" | grep -qi "pushed\|digest\|latest"; then
      pass "image pushed to ECR: cicd-lab-app-$STUDENT_NAME:$GIT_SHA"
    else
      fail "ECR push failed: $PUSH_RESULT"
    fi
  else
    skip "ECR push skipped (docker not available or ECR login failed)"
  fi

  # Clean up ECR repo immediately (test only)
  aws ecr delete-repository --repository-name cicd-lab-app-$STUDENT_NAME \
    --region "$REGION" --force &>/dev/null 2>&1 || true
else
  skip "AWS account not accessible"
  export ECR_REGISTRY="placeholder"
  export ECR_REPO="test"
fi
export GIT_SHA="${GIT_SHA:-test}"

# ─── Step 4: Deploy with kubectl ────────────────────────────────────────────

echo ""
echo "Step 4 — Kubernetes Deploy:"
kubectl create namespace "$NS_CICD" &>/dev/null

# Create deployment and service directly (simulates envsubst of k8s/deployment.yaml)
kubectl create deployment cicd-demo --image=nginx:1.25-alpine --replicas=3 -n "$NS_CICD" &>/dev/null
kubectl expose deployment cicd-demo --port=80 --target-port=80 --name=cicd-demo-svc -n "$NS_CICD" &>/dev/null
wait_for_deploy "$NS_CICD" cicd-demo 90

READY=$(kubectl get deployment cicd-demo -n "$NS_CICD" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "deployment has 3 replicas" "3" "$READY"

# Annotate with git SHA
kubectl annotate deployment cicd-demo -n "$NS_CICD" "git-commit=$GIT_SHA" &>/dev/null
ANNOTATION=$(kubectl get deployment cicd-demo -n "$NS_CICD" \
  -o jsonpath='{.metadata.annotations.git-commit}' 2>/dev/null)
assert_eq "deployment annotated with git SHA" "$GIT_SHA" "$ANNOTATION"

# Curl test
CURL_RESPONSE=$(kubectl run curl-deploy-test --image=curlimages/curl --rm -i --restart=Never \
  -n "$NS_CICD" --timeout=30s -- curl -s cicd-demo-svc 2>/dev/null)
if [ -n "$CURL_RESPONSE" ]; then
  pass "curl to cicd-demo-svc returned response"
else
  fail "curl to cicd-demo-svc returned empty response"
fi

# ─── Step 7: Simulate code change and rolling update ────────────────────────

echo ""
echo "Step 7 — Pipeline Code Change:"

# Simulate v2 deployment by updating the image (triggers rolling update)
kubectl set image deployment/cicd-demo nginx=nginx:1.26-alpine -n "$NS_CICD" &>/dev/null 2>&1 || true
kubectl annotate deployment cicd-demo -n "$NS_CICD" "git-commit=v2-sha" --overwrite &>/dev/null

UPDATED_ANNOTATION=$(kubectl get deployment cicd-demo -n "$NS_CICD" \
  -o jsonpath='{.metadata.annotations.git-commit}' 2>/dev/null)
assert_eq "annotation updated after code change" "v2-sha" "$UPDATED_ANNOTATION"

# ─── Step 3-6: ArgoCD GitOps demo (matches README) ──────────────────────────
# The README's ArgoCD walkthrough deploys an http-echo "Hello from ArgoCD v1"
# demo app (Steps 3+5), updates it to v2 then rolls back (Step 6), and creates
# the declarative Application from argocd-app.yaml (Step 4). The demo-app part is
# plain kubectl and runs whenever a cluster is reachable; the Application sync
# checks need the ArgoCD control plane and degrade to skip when it is absent.

echo ""
echo "Step 3-6 — ArgoCD:"

kubectl create namespace "$NS_ARGOCD" &>/dev/null

# Steps 3 + 5: deploy the README's local demo-app manifests (http-echo v1)
cat <<'EOF' | kubectl apply -n "$NS_ARGOCD" -f - &>/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  labels: { app: demo-app }
spec:
  replicas: 2
  selector:
    matchLabels: { app: demo-app }
  template:
    metadata:
      labels: { app: demo-app }
    spec:
      containers:
      - name: app
        image: hashicorp/http-echo
        args: ["-text=Hello from ArgoCD v1", "-listen=:8080"]
        ports:
        - containerPort: 8080
        resources:
          requests: { cpu: 50m, memory: 32Mi }
          limits: { cpu: 100m, memory: 64Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: demo-app-svc
spec:
  selector: { app: demo-app }
  ports:
  - port: 80
    targetPort: 8080
EOF

if wait_for_deploy "$NS_ARGOCD" demo-app 90; then
  # Step 5: app responds with the v1 text
  V1_RESPONSE=$(kubectl run argocd-curl-v1 --image=curlimages/curl --rm -i --restart=Never \
    -n "$NS_ARGOCD" --timeout=30s -- curl -s demo-app-svc 2>/dev/null)
  if [ -n "$V1_RESPONSE" ]; then
    assert_contains "demo-app responds 'Hello from ArgoCD v1'" "$V1_RESPONSE" "Hello from ArgoCD v1"
  else
    skip "demo-app v1 curl returned empty (cluster networking unavailable)"
  fi

  # Step 6: update the echoed text to v2, confirm it, then roll back to v1
  kubectl patch deployment demo-app -n "$NS_ARGOCD" --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["-text=Hello from ArgoCD v2","-listen=:8080"]}]' &>/dev/null
  wait_for_deploy "$NS_ARGOCD" demo-app 90
  V2_RESPONSE=$(kubectl run argocd-curl-v2 --image=curlimages/curl --rm -i --restart=Never \
    -n "$NS_ARGOCD" --timeout=30s -- curl -s demo-app-svc 2>/dev/null)
  if [ -n "$V2_RESPONSE" ]; then
    assert_contains "demo-app responds 'Hello from ArgoCD v2' after update" "$V2_RESPONSE" "Hello from ArgoCD v2"
  else
    skip "demo-app v2 curl returned empty"
  fi

  kubectl rollout undo deployment/demo-app -n "$NS_ARGOCD" &>/dev/null
  wait_for_deploy "$NS_ARGOCD" demo-app 90
  RB_RESPONSE=$(kubectl run argocd-curl-rb --image=curlimages/curl --rm -i --restart=Never \
    -n "$NS_ARGOCD" --timeout=30s -- curl -s demo-app-svc 2>/dev/null)
  if [ -n "$RB_RESPONSE" ]; then
    assert_contains "demo-app rolled back to 'Hello from ArgoCD v1'" "$RB_RESPONSE" "Hello from ArgoCD v1"
  else
    skip "demo-app rollback curl returned empty"
  fi
else
  skip "demo-app deployment did not become ready (cluster unavailable)"
fi

# Step 4: declarative ArgoCD Application (argocd-app.yaml). Needs the ArgoCD
# control plane, so gate behind the argocd namespace running.
ARGOCD_RUNNING=false
if kubectl get pods -n argocd --no-headers 2>/dev/null | grep -q Running; then
  ARGOCD_RUNNING=true
  pass "argocd pods running"

  # Verify CLI (optional)
  if command -v argocd &>/dev/null; then
    assert_cmd "argocd CLI works" argocd version --client
  else
    skip "argocd CLI not installed"
  fi

  # Verify Application CRD exists
  assert_cmd "Application CRD exists" kubectl get crd applications.argoproj.io

  # Apply argocd-app.yaml with envsubst
  envsubst '$STUDENT_NAME' < "$LAB_DIR/argocd-app.yaml" | kubectl apply -f - &>/dev/null 2>&1
  sleep 3

  APP_EXISTS=$(kubectl get application "demo-$STUDENT_NAME" -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "ArgoCD Application created" "1" "$APP_EXISTS"

  # Verify Application spec fields match argocd-app.yaml / the README
  APP_DEST_NS=$(kubectl get application "demo-$STUDENT_NAME" -n argocd \
    -o jsonpath='{.spec.destination.namespace}' 2>/dev/null)
  assert_eq "ArgoCD app targets correct namespace" "$NS_ARGOCD" "$APP_DEST_NS"

  APP_REPO=$(kubectl get application "demo-$STUDENT_NAME" -n argocd \
    -o jsonpath='{.spec.source.repoURL}' 2>/dev/null)
  assert_contains "ArgoCD app sources the example-apps repo" "$APP_REPO" "argocd-example-apps"

  APP_SYNC_POLICY=$(kubectl get application "demo-$STUDENT_NAME" -n argocd \
    -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' 2>/dev/null)
  assert_eq "ArgoCD app has selfHeal enabled" "true" "$APP_SYNC_POLICY"

  APP_PRUNE=$(kubectl get application "demo-$STUDENT_NAME" -n argocd \
    -o jsonpath='{.spec.syncPolicy.automated.prune}' 2>/dev/null)
  assert_eq "ArgoCD app has prune enabled" "true" "$APP_PRUNE"

  # README Step 4 checkpoint: the app converges to Synced + Healthy against the
  # public argocd-example-apps repo. Repo egress may be blocked in some clusters,
  # so degrade to skip (not fail) if it doesn't converge within the window.
  SYNC_STATUS=""
  HEALTH_STATUS=""
  for i in $(seq 1 24); do
    SYNC_STATUS=$(kubectl get application "demo-$STUDENT_NAME" -n argocd \
      -o jsonpath='{.status.sync.status}' 2>/dev/null)
    HEALTH_STATUS=$(kubectl get application "demo-$STUDENT_NAME" -n argocd \
      -o jsonpath='{.status.health.status}' 2>/dev/null)
    if [ "$SYNC_STATUS" = "Synced" ] && [ "$HEALTH_STATUS" = "Healthy" ]; then
      break
    fi
    sleep 5
  done
  if [ "$SYNC_STATUS" = "Synced" ]; then
    pass "ArgoCD Application reached Synced"
  else
    skip "ArgoCD Application not Synced (status: ${SYNC_STATUS:-unknown}; repo may be unreachable)"
  fi
  if [ "$HEALTH_STATUS" = "Healthy" ]; then
    pass "ArgoCD Application reached Healthy"
  else
    skip "ArgoCD Application not Healthy (status: ${HEALTH_STATUS:-unknown})"
  fi

  # Clean up ArgoCD application
  kubectl delete application "demo-$STUDENT_NAME" -n argocd --ignore-not-found &>/dev/null
else
  skip "argocd not running"
fi

# ─── Step 9-11: FluxCD ──────────────────────────────────────────────────────

echo ""
echo "Step 9-11 — FluxCD:"
FLUX_RUNNING=false
if kubectl get pods -n flux-system --no-headers 2>/dev/null | grep -q Running; then
  FLUX_RUNNING=true
  pass "flux pods running"

  FLUX_CHECK=$(flux check 2>&1)
  assert_contains "flux check passes" "$FLUX_CHECK" "all checks passed"

  # Verify Flux CRDs
  FLUX_CRDS=$(kubectl get crds 2>/dev/null | grep flux || true)
  assert_contains "Flux CRDs installed" "$FLUX_CRDS" "flux"

  # Check flux sources
  if flux get sources git &>/dev/null 2>&1; then
    pass "flux get sources git works"
  else
    skip "no flux git sources configured"
  fi

  if flux get sources helm &>/dev/null 2>&1; then
    pass "flux get sources helm works"
  else
    skip "no flux helm sources configured"
  fi

  # Verify flux kustomizations
  KUSTOMIZATION_OUTPUT=$(flux get kustomizations 2>&1 || true)
  if echo "$KUSTOMIZATION_OUTPUT" | grep -q "flux-system"; then
    pass "flux kustomizations contains flux-system"
  else
    skip "flux kustomizations did not contain flux-system"
  fi

  # Step 10: Create namespace and apply HelmRepository
  kubectl create namespace "$NS_FLUX" &>/dev/null

  envsubst '$STUDENT_NAME' < "$LAB_DIR/helm-source.yaml" | kubectl apply -f - &>/dev/null
  sleep 5

  HR_COUNT=$(kubectl get helmrepository "podinfo-$STUDENT_NAME" -n flux-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "HelmRepository created" "1" "$HR_COUNT"

  HR_URL=$(kubectl get helmrepository "podinfo-$STUDENT_NAME" -n flux-system \
    -o jsonpath='{.spec.url}' 2>/dev/null)
  assert_contains "HelmRepository points to podinfo" "$HR_URL" "podinfo"

  # Apply HelmRelease
  envsubst '$STUDENT_NAME' < "$LAB_DIR/helm-release.yaml" | kubectl apply -f - &>/dev/null
  sleep 5

  HELM_REL_COUNT=$(kubectl get helmrelease "lab-podinfo-$STUDENT_NAME" -n "$NS_FLUX" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "HelmRelease created" "1" "$HELM_REL_COUNT"

  HELM_REL_CHART=$(kubectl get helmrelease "lab-podinfo-$STUDENT_NAME" -n "$NS_FLUX" \
    -o jsonpath='{.spec.chart.spec.chart}' 2>/dev/null)
  assert_eq "HelmRelease chart is podinfo" "podinfo" "$HELM_REL_CHART"

  HELM_REL_REPLICAS=$(kubectl get helmrelease "lab-podinfo-$STUDENT_NAME" -n "$NS_FLUX" \
    -o jsonpath='{.spec.values.replicaCount}' 2>/dev/null)
  assert_eq "HelmRelease specifies 2 replicas" "2" "$HELM_REL_REPLICAS"

  HELM_REL_REMEDIATION=$(kubectl get helmrelease "lab-podinfo-$STUDENT_NAME" -n "$NS_FLUX" \
    -o jsonpath='{.spec.install.remediation.retries}' 2>/dev/null)
  assert_eq "HelmRelease install remediation retries is 3" "3" "$HELM_REL_REMEDIATION"

  # Wait for HelmRelease to reconcile and deploy
  echo ""
  echo "  Waiting for HelmRelease reconciliation (up to 120s)..."
  HELM_READY=false
  for i in $(seq 1 24); do
    HR_STATUS=$(kubectl get helmrelease "lab-podinfo-$STUDENT_NAME" -n "$NS_FLUX" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$HR_STATUS" = "True" ]; then
      HELM_READY=true
      break
    fi
    sleep 5
  done

  if [ "$HELM_READY" = "true" ]; then
    pass "HelmRelease reconciled to Ready"

    # Verify helm release created by Flux
    FLUX_HELM_LIST=$(helm list -n "$NS_FLUX" 2>/dev/null)
    assert_contains "helm list shows flux-managed release" "$FLUX_HELM_LIST" "lab-podinfo-$STUDENT_NAME"

    # Verify pods are running. A HelmRelease reaching Ready means Helm reported
    # the release deployed — the podinfo Pods may still be scheduling/pulling,
    # so wait for them to reach Running before counting (and before drift below).
    FLUX_PODS=0
    for i in $(seq 1 24); do
      FLUX_PODS=$(kubectl get pods -n "$NS_FLUX" \
        -l "app.kubernetes.io/name=lab-podinfo-$STUDENT_NAME" \
        --no-headers 2>/dev/null | grep -c Running || true)
      [ "$FLUX_PODS" -ge 2 ] && break
      sleep 5
    done
    if [ "$FLUX_PODS" -ge 2 ]; then
      pass "HelmRelease pods running ($FLUX_PODS replicas)"
    else
      fail "expected 2 running pods, got $FLUX_PODS"
    fi

    # Step 11: Drift detection
    echo ""
    echo "Step 11 — Drift Detection:"

    # Scale manually to create drift
    kubectl scale deployment -n "$NS_FLUX" \
      -l "app.kubernetes.io/name=lab-podinfo-$STUDENT_NAME" \
      --replicas=5 &>/dev/null
    sleep 3

    DRIFT_REPLICAS=$(kubectl get deployment -n "$NS_FLUX" \
      -l "app.kubernetes.io/name=lab-podinfo-$STUDENT_NAME" \
      -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null)
    assert_eq "manual scale created drift (5 replicas)" "5" "$DRIFT_REPLICAS"

    # Force reconciliation
    flux reconcile helmrelease "lab-podinfo-$STUDENT_NAME" -n "$NS_FLUX" &>/dev/null 2>&1

    # Wait for Flux to revert
    REVERTED=false
    for i in $(seq 1 24); do
      CURRENT=$(kubectl get deployment -n "$NS_FLUX" \
        -l "app.kubernetes.io/name=lab-podinfo-$STUDENT_NAME" \
        -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null)
      if [ "$CURRENT" = "2" ]; then
        REVERTED=true
        break
      fi
      sleep 5
    done

    if [ "$REVERTED" = "true" ]; then
      pass "Flux reverted drift back to 2 replicas"
    else
      FINAL=$(kubectl get deployment -n "$NS_FLUX" \
        -l "app.kubernetes.io/name=lab-podinfo-$STUDENT_NAME" \
        -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null)
      fail "Flux did not revert drift (replicas: $FINAL, expected: 2)"
    fi
  else
    skip "HelmRelease did not reach Ready state within 120s"
  fi

  # Clean up Flux resources
  kubectl delete helmrelease "lab-podinfo-$STUDENT_NAME" -n "$NS_FLUX" --ignore-not-found &>/dev/null
  kubectl delete helmrepository "podinfo-$STUDENT_NAME" -n flux-system --ignore-not-found &>/dev/null
else
  skip "flux not running"
fi

# ─── Cleanup ────────────────────────────────────────────────────────────────

rm -rf "$TMPDIR"
docker rmi "my-app:$GIT_SHA" "my-app:latest" &>/dev/null 2>&1 || true
cleanup_ns "$NS_CICD"
cleanup_ns "$NS_ARGOCD"
cleanup_ns "$NS_FLUX"
summary
