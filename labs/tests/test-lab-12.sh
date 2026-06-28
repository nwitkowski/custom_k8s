#!/bin/bash
###############################################################################
# Lab 12 Test: Helm and Templating
# Covers: Helm basics, install, get values/manifest, upgrade, rollback,
#         custom chart with ConfigMap template, lint, template --set,
#         package, install custom chart, verify ConfigMap and env vars
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="helm-lab-$STUDENT_NAME"
echo "=== Lab 12: Helm and Templating (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Step 1: Verify Helm and add repository ─────────────────────────────────

echo "Step 1 — Helm Basics:"
assert_cmd "helm version works" helm version --short

helm repo add podinfo https://stefanprodan.github.io/podinfo &>/dev/null
helm repo update &>/dev/null
assert_cmd "podinfo repo added" helm repo list

SEARCH=$(helm search repo podinfo/podinfo 2>/dev/null)
assert_contains "podinfo chart found" "$SEARCH" "podinfo/podinfo"

SHOW_CHART=$(helm show chart podinfo/podinfo 2>/dev/null)
assert_contains "helm show chart returns metadata" "$SHOW_CHART" "name: podinfo"

# ─── Step 2: Install a chart ────────────────────────────────────────────────

echo ""
echo "Step 2 — Chart Install:"
helm install my-podinfo podinfo/podinfo -n "$NS" \
  --set replicaCount=2 \
  --set service.type=ClusterIP \
  --wait --timeout 120s &>/dev/null

RELEASE=$(helm list -n "$NS" --short 2>/dev/null)
assert_contains "release installed" "$RELEASE" "my-podinfo"

STATUS=$(helm status my-podinfo -n "$NS" -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null)
assert_eq "release status is deployed" "deployed" "$STATUS"

REPLICAS=$(kubectl get deployment -n "$NS" -l app.kubernetes.io/name=my-podinfo \
  -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null)
assert_eq "podinfo has 2 replicas" "2" "$REPLICAS"

# ─── Step 3: Explore the release (get values, get manifest) ─────────────────

echo ""
echo "Step 3 — Explore Release:"

GET_VALUES=$(helm get values my-podinfo -n "$NS" 2>/dev/null)
assert_contains "helm get values shows replicaCount" "$GET_VALUES" "replicaCount"

GET_VALUES_ALL=$(helm get values my-podinfo -n "$NS" --all 2>/dev/null)
assert_contains "helm get values --all returns full values" "$GET_VALUES_ALL" "replicaCount"

GET_MANIFEST=$(helm get manifest my-podinfo -n "$NS" 2>/dev/null)
assert_contains "helm get manifest contains Deployment" "$GET_MANIFEST" "kind: Deployment"
assert_contains "helm get manifest contains Service" "$GET_MANIFEST" "kind: Service"

# ─── Step 4: Upgrade the release ────────────────────────────────────────────

echo ""
echo "Step 4 — Chart Upgrade:"
helm upgrade my-podinfo podinfo/podinfo -n "$NS" \
  --set replicaCount=3 \
  --set service.type=ClusterIP \
  --wait --timeout 120s &>/dev/null

REVISION=$(helm history my-podinfo -n "$NS" -o json 2>/dev/null | jq 'length' 2>/dev/null)
assert_eq "release at revision 2" "2" "$REVISION"

# Check the desired replica count (.spec.replicas), set immediately by the
# upgrade — not .status.readyReplicas, which can lag at 2 during the 2->3 roll
# since helm --wait returns once the deployment is "available".
REPLICAS_UP=$(kubectl get deployment -n "$NS" -l app.kubernetes.io/name=my-podinfo \
  -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null)
assert_eq "upgraded to 3 replicas" "3" "$REPLICAS_UP"

LIST_REV=$(helm list -n "$NS" -o json 2>/dev/null | jq -r '.[0].revision' 2>/dev/null)
assert_eq "helm list shows revision 2" "2" "$LIST_REV"

# ─── Step 5: Release history and rollback ────────────────────────────────────

echo ""
echo "Step 5 — Release History and Rollback:"

HISTORY=$(helm history my-podinfo -n "$NS" 2>/dev/null)
assert_contains "history shows multiple revisions" "$HISTORY" "1"

helm rollback my-podinfo 1 -n "$NS" --wait &>/dev/null
sleep 10

REPLICAS_RB=$(kubectl get deployment -n "$NS" -l app.kubernetes.io/name=my-podinfo \
  -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null)
assert_eq "rolled back to 2 replicas" "2" "$REPLICAS_RB"

REVISION_AFTER_RB=$(helm history my-podinfo -n "$NS" -o json 2>/dev/null | jq 'length' 2>/dev/null)
assert_eq "rollback creates revision 3" "3" "$REVISION_AFTER_RB"

# ─── Step 6-7: Create and customize a chart ──────────────────────────────────

echo ""
echo "Step 6-7 — Custom Chart with ConfigMap:"

TMPDIR=$(mktemp -d)
helm create "$TMPDIR/mychart" &>/dev/null
assert_cmd "chart scaffolded" test -f "$TMPDIR/mychart/Chart.yaml"
assert_cmd "values.yaml exists" test -f "$TMPDIR/mychart/values.yaml"
assert_cmd "deployment template exists" test -f "$TMPDIR/mychart/templates/deployment.yaml"
assert_cmd "helpers template exists" test -f "$TMPDIR/mychart/templates/_helpers.tpl"

# Create ConfigMap template (Step 7)
cat > "$TMPDIR/mychart/templates/configmap.yaml" <<'CMEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "mychart.fullname" . }}-config
  labels:
    {{- include "mychart.labels" . | nindent 4 }}
data:
  APP_ENV: {{ .Values.appConfig.environment | quote }}
  APP_LOG_LEVEL: {{ .Values.appConfig.logLevel | quote }}
  {{- if .Values.appConfig.customMessage }}
  CUSTOM_MESSAGE: {{ .Values.appConfig.customMessage | quote }}
  {{- end }}
CMEOF

# Add appConfig values to values.yaml
cat >> "$TMPDIR/mychart/values.yaml" <<'VALEOF'

appConfig:
  environment: production
  logLevel: info
  customMessage: "Hello from Helm!"
VALEOF

# Add envFrom to deployment template
# Insert envFrom block into the container spec
awk '/ports:/{print "          envFrom:"; print "          - configMapRef:"; print "              name: {{ include \"mychart.fullname\" . }}-config"}1' \
  "$TMPDIR/mychart/templates/deployment.yaml" > "$TMPDIR/mychart/templates/deployment.yaml.tmp" && \
  mv "$TMPDIR/mychart/templates/deployment.yaml.tmp" "$TMPDIR/mychart/templates/deployment.yaml"

# Verify the customizations were actually written to the chart on disk
assert_cmd "ConfigMap template file created" test -f "$TMPDIR/mychart/templates/configmap.yaml"
assert_contains "configmap.yaml wires APP_ENV from appConfig" \
  "$(cat "$TMPDIR/mychart/templates/configmap.yaml")" "APP_ENV"
assert_contains "values.yaml has appConfig block" \
  "$(cat "$TMPDIR/mychart/values.yaml")" "appConfig"
assert_contains "deployment template references envFrom" \
  "$(cat "$TMPDIR/mychart/templates/deployment.yaml")" "envFrom"
assert_contains "deployment envFrom references the config ConfigMap" \
  "$(cat "$TMPDIR/mychart/templates/deployment.yaml")" "configMapRef"

# Verify the chart still lints and that `helm template` renders the wiring
# end-to-end (matches the README Step 7 verification: lint passes and
# `helm template r mychart/ | grep -A2 envFrom` shows the block).
assert_cmd "helm lint passes after customization" helm lint "$TMPDIR/mychart"
STEP7_TEMPLATE=$(helm template r "$TMPDIR/mychart" 2>/dev/null)
assert_contains "rendered template includes envFrom wiring" "$STEP7_TEMPLATE" "envFrom"
assert_contains "rendered template includes configMapRef" "$STEP7_TEMPLATE" "configMapRef"
assert_contains "rendered template renders the ConfigMap object" "$STEP7_TEMPLATE" "kind: ConfigMap"

# ─── Step 8: Validate and debug ─────────────────────────────────────────────

echo ""
echo "Step 8 — Validate and Debug:"

assert_cmd "helm lint passes" helm lint "$TMPDIR/mychart"

TEMPLATE=$(helm template my-release "$TMPDIR/mychart" 2>/dev/null)
assert_contains "helm template renders Deployment" "$TEMPLATE" "kind: Deployment"
assert_contains "helm template renders ConfigMap" "$TEMPLATE" "kind: ConfigMap"
assert_contains "template contains APP_ENV" "$TEMPLATE" "APP_ENV"
assert_contains "template default env is production" "$TEMPLATE" "production"

# Test --set overrides
TEMPLATE_OVERRIDE=$(helm template my-release "$TMPDIR/mychart" \
  --set appConfig.environment=staging 2>/dev/null)
assert_contains "template --set overrides environment to staging" "$TEMPLATE_OVERRIDE" "staging"

TEMPLATE_LOGLEVEL=$(helm template my-release "$TMPDIR/mychart" \
  --set appConfig.logLevel=debug 2>/dev/null)
assert_contains "template --set overrides logLevel to debug" "$TEMPLATE_LOGLEVEL" "debug"

# Dry-run install
DRYRUN=$(helm install my-release "$TMPDIR/mychart" -n "$NS" --dry-run --debug 2>/dev/null)
assert_contains "dry-run renders manifests" "$DRYRUN" "MANIFEST"

# ─── Step 9: Package and install custom chart ────────────────────────────────

echo ""
echo "Step 9 — Package and Install Custom Chart:"

helm package "$TMPDIR/mychart" -d "$TMPDIR" &>/dev/null
assert_cmd "chart packaged" ls "$TMPDIR"/mychart-*.tgz

# Install the custom chart with overrides
helm install my-custom-app "$TMPDIR"/mychart-*.tgz \
  -n "$NS" \
  --set appConfig.environment=development \
  --set appConfig.logLevel=debug \
  --wait --timeout 120s &>/dev/null

CUSTOM_RELEASE=$(helm list -n "$NS" --short 2>/dev/null)
assert_contains "custom chart release installed" "$CUSTOM_RELEASE" "my-custom-app"

CUSTOM_STATUS=$(helm status my-custom-app -n "$NS" -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null)
assert_eq "custom chart status is deployed" "deployed" "$CUSTOM_STATUS"

# Verify ConfigMap created with correct values
CM_DATA=$(kubectl get configmap my-custom-app-mychart-config -n "$NS" -o json 2>/dev/null)
if [ -n "$CM_DATA" ]; then
  pass "ConfigMap my-custom-app-mychart-config created"

  CM_ENV=$(echo "$CM_DATA" | jq -r '.data.APP_ENV' 2>/dev/null)
  assert_eq "ConfigMap APP_ENV is development" "development" "$CM_ENV"

  CM_LOG=$(echo "$CM_DATA" | jq -r '.data.APP_LOG_LEVEL' 2>/dev/null)
  assert_eq "ConfigMap APP_LOG_LEVEL is debug" "debug" "$CM_LOG"

  CM_MSG=$(echo "$CM_DATA" | jq -r '.data.CUSTOM_MESSAGE' 2>/dev/null)
  assert_eq "ConfigMap CUSTOM_MESSAGE is Hello from Helm!" "Hello from Helm!" "$CM_MSG"
else
  fail "ConfigMap my-custom-app-mychart-config not found"
fi

# Verify env vars in running pod
POD_NAME=$(kubectl get pod -n "$NS" -l app.kubernetes.io/instance=my-custom-app \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_NAME" ]; then
  POD_ENV=$(kubectl exec -n "$NS" "$POD_NAME" -- env 2>/dev/null)
  assert_contains "pod has APP_ENV=development" "$POD_ENV" "APP_ENV=development"
  assert_contains "pod has APP_LOG_LEVEL=debug" "$POD_ENV" "APP_LOG_LEVEL=debug"
  assert_contains "pod has CUSTOM_MESSAGE" "$POD_ENV" "CUSTOM_MESSAGE=Hello from Helm!"
else
  fail "no pod found for my-custom-app"
fi

# Verify resources created by the chart
CUSTOM_DEPLOY=$(kubectl get deployment -n "$NS" -l app.kubernetes.io/instance=my-custom-app \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_eq "custom chart created deployment" "1" "$CUSTOM_DEPLOY"

CUSTOM_SVC=$(kubectl get service -n "$NS" -l app.kubernetes.io/instance=my-custom-app \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_eq "custom chart created service" "1" "$CUSTOM_SVC"

rm -rf "$TMPDIR"

# ─── Cleanup ────────────────────────────────────────────────────────────────

helm uninstall my-podinfo -n "$NS" &>/dev/null
helm uninstall my-custom-app -n "$NS" &>/dev/null
cleanup_ns "$NS"
summary
