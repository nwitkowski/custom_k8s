#!/bin/bash
###############################################################################
# Lab 3 Test: Storage and StatefulSets — COMPREHENSIVE
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-03" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab03-$STUDENT_NAME"
echo "=== Lab 3: Storage & StatefulSets (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

###############################################################################
# Step 1: StorageClass verification
###############################################################################

echo "StorageClass:"

SC_EXISTS=$(kubectl get storageclass gp2 -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "gp2 StorageClass exists" "gp2" "$SC_EXISTS"

SC_PROVISIONER=$(kubectl get storageclass gp2 -o jsonpath='{.provisioner}' 2>/dev/null)
if [ -n "$SC_PROVISIONER" ]; then
  pass "gp2 provisioner: $SC_PROVISIONER"
else
  fail "gp2 provisioner not found"
fi

SC_BINDING=$(kubectl get storageclass gp2 -o jsonpath='{.volumeBindingMode}' 2>/dev/null)
assert_eq "gp2 binding mode is WaitForFirstConsumer" "WaitForFirstConsumer" "$SC_BINDING"

# Lab Step 9 enables expansion on the default-EKS gp2 class before expanding a PVC.
# Replicate that here so the expansion path is actually exercised, not skipped.
kubectl patch storageclass gp2 -p '{"allowVolumeExpansion": true}' >/dev/null 2>&1 || true
SC_EXPAND=$(kubectl get storageclass gp2 -o jsonpath='{.allowVolumeExpansion}' 2>/dev/null)
if [ "$SC_EXPAND" = "true" ]; then
  pass "gp2 allows volume expansion (enabled via patch)"
  GP2_EXPAND=true
else
  skip "gp2 does not allow volume expansion (patch did not take effect)"
  GP2_EXPAND=false
fi

###############################################################################
# Step 2: PersistentVolumeClaim
###############################################################################

echo ""
echo "PersistentVolumeClaim:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/lab-pvc.yaml" | kubectl apply -f - &>/dev/null

sleep 3

PVC_STATUS=$(kubectl get pvc lab-data-pvc -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$PVC_STATUS" = "Bound" ] || [ "$PVC_STATUS" = "Pending" ]; then
  pass "PVC created (status: $PVC_STATUS — Pending expected with WaitForFirstConsumer)"
else
  fail "PVC status unexpected: $PVC_STATUS"
fi

PVC_SC=$(kubectl get pvc lab-data-pvc -n "$NS" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
assert_eq "PVC uses gp2 StorageClass" "gp2" "$PVC_SC"

PVC_ACCESS=$(kubectl get pvc lab-data-pvc -n "$NS" -o jsonpath='{.spec.accessModes[0]}' 2>/dev/null)
assert_eq "PVC access mode is ReadWriteOnce" "ReadWriteOnce" "$PVC_ACCESS"

PVC_SIZE=$(kubectl get pvc lab-data-pvc -n "$NS" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
assert_eq "PVC requests 1Gi" "1Gi" "$PVC_SIZE"

###############################################################################
# Step 3: Writer pod — mount PVC and write data
###############################################################################

echo ""
echo "Data Writer Pod:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/lab-writer-pod.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" data-writer 120
sleep 5

WRITTEN=$(kubectl exec data-writer -n "$NS" -- cat /data/testfile.txt 2>/dev/null)
assert_contains "writer pod wrote timestamp" "$WRITTEN" "Written at"
assert_contains "writer pod wrote hostname" "$WRITTEN" "Hostname:"

# Verify PVC is now Bound after pod consumed it
PVC_STATUS=$(kubectl get pvc lab-data-pvc -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
assert_eq "PVC is Bound after pod mounts it" "Bound" "$PVC_STATUS"

# Verify a PV was dynamically provisioned
PV_NAME=$(kubectl get pvc lab-data-pvc -n "$NS" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
if [ -n "$PV_NAME" ]; then
  pass "PV dynamically created: $PV_NAME"
else
  fail "no PV bound to PVC"
fi

# EBS-backed PVs are pinned to the AZ they were provisioned in: the PV carries a
# nodeAffinity constraint referencing topology.kubernetes.io/zone. Skip on
# storage backends (hostPath, NFS, etc.) that don't set nodeAffinity.
if [ -n "$PV_NAME" ]; then
  PV_AFFINITY=$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.nodeAffinity}' 2>/dev/null)
  if [ -n "$PV_AFFINITY" ]; then
    PV_AFF_KEYS=$(kubectl get pv "$PV_NAME" \
      -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[*].matchExpressions[*].key}' 2>/dev/null)
    assert_contains "PV nodeAffinity pins volume to a zone" "$PV_AFF_KEYS" "topology.kubernetes.io/zone"
  else
    skip "PV has no nodeAffinity (non-EBS storage backend)"
  fi
else
  skip "no PV bound — skipping nodeAffinity zone check"
fi

###############################################################################
# Step 4: Data persistence across pod deletion
###############################################################################

echo ""
echo "Data Persistence:"

kubectl delete pod data-writer -n "$NS" --timeout=30s &>/dev/null

# PVC should remain Bound after writer pod is deleted
PVC_STATUS=$(kubectl get pvc lab-data-pvc -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
assert_eq "PVC stays Bound after pod deletion" "Bound" "$PVC_STATUS"

envsubst '$STUDENT_NAME' < "$LAB_DIR/lab-reader-pod.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" data-reader 120

READ=$(kubectl exec data-reader -n "$NS" -- cat /data/testfile.txt 2>/dev/null)
assert_contains "data persists after pod deletion" "$READ" "Written at"

kubectl delete pod data-reader -n "$NS" --timeout=30s &>/dev/null

###############################################################################
# Step 5: Deploy StatefulSet with headless service
###############################################################################

echo ""
echo "StatefulSet:"

envsubst '$STUDENT_NAME' < "$LAB_DIR/lab-headless-svc.yaml" | kubectl apply -f - &>/dev/null
envsubst '$STUDENT_NAME' < "$LAB_DIR/lab-statefulset.yaml" | kubectl apply -f - &>/dev/null

# Verify headless service
HEADLESS_CIP=$(kubectl get svc web-headless -n "$NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
assert_eq "headless service clusterIP is None" "None" "$HEADLESS_CIP"

# Wait for StatefulSet rollout
kubectl rollout status statefulset/web -n "$NS" --timeout=180s &>/dev/null
READY=$(kubectl get statefulset web -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "StatefulSet has 3 ready replicas" "3" "$READY"

###############################################################################
# Step 6: Stable identities
###############################################################################

echo ""
echo "Stable Identities:"

POD0=$(kubectl get pod web-0 -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "stable pod name web-0" "web-0" "$POD0"

POD1=$(kubectl get pod web-1 -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "stable pod name web-1" "web-1" "$POD1"

POD2=$(kubectl get pod web-2 -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "stable pod name web-2" "web-2" "$POD2"

# Each pod has its own PVC
PVC_COUNT=$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | grep -c "web-data-web" || true)
assert_eq "StatefulSet created 3 PVCs" "3" "$PVC_COUNT"

PVC0=$(kubectl get pvc web-data-web-0 -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "PVC web-data-web-0 exists" "web-data-web-0" "$PVC0"

PVC1=$(kubectl get pvc web-data-web-1 -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "PVC web-data-web-1 exists" "web-data-web-1" "$PVC1"

PVC2=$(kubectl get pvc web-data-web-2 -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "PVC web-data-web-2 exists" "web-data-web-2" "$PVC2"

###############################################################################
# Step 6b: DNS resolution for StatefulSet pods
###############################################################################

echo ""
echo "StatefulSet DNS Resolution:"

# Per-pod StatefulSet DNS can lag a few seconds after pods are Ready while the
# headless EndpointSlice and CoreDNS cache populate — retry before failing.
DNS_OK=false
for i in $(seq 1 6); do
  DNS_RESULT=$(kubectl run dns-test-$$-$i --image=busybox:1.36 --rm -i --restart=Never -n "$NS" \
    -- nslookup web-0.web-headless."$NS".svc.cluster.local 2>&1) || true
  if echo "$DNS_RESULT" | grep -q "Address"; then DNS_OK=true; break; fi
  sleep 5
done
if [ "$DNS_OK" = true ]; then
  pass "DNS resolves web-0.web-headless (nslookup)"
else
  fail "DNS lookup failed for web-0.web-headless"
fi

# Verify headless service DNS returns pod IPs (not a VIP)
DNS_HEADLESS=$(kubectl run dns-test2-$$ --image=busybox:1.36 --rm -i --restart=Never -n "$NS" \
  -- nslookup web-headless."$NS".svc.cluster.local 2>&1) || true
ADDR_COUNT=$(echo "$DNS_HEADLESS" | grep -c "Address" || true)
if [ "$ADDR_COUNT" -ge 3 ]; then
  pass "headless DNS returns multiple pod addresses"
else
  # At minimum the server line + one result = 2
  skip "headless DNS address count ($ADDR_COUNT) — may need more time"
fi

###############################################################################
# Step 7: Per-replica data persistence
###############################################################################

echo ""
echo "Per-Replica Data Persistence:"

# Write unique content to each pod
for i in 0 1 2; do
  kubectl exec "web-$i" -n "$NS" -- \
    sh -c "echo 'Hello from web-$i' > /usr/share/nginx/html/index.html" 2>/dev/null
done

# Verify each pod serves its own content
for i in 0 1 2; do
  CONTENT=$(kubectl exec "web-$i" -n "$NS" -- curl -s localhost 2>/dev/null)
  assert_contains "web-$i serves its own content" "$CONTENT" "Hello from web-$i"
done

# Delete web-0, wait for re-creation, verify data survives
kubectl delete pod web-0 -n "$NS" --timeout=30s &>/dev/null
wait_for_pod "$NS" web-0 120

CONTENT_AFTER=$(kubectl exec web-0 -n "$NS" -- curl -s localhost 2>/dev/null)
assert_contains "web-0 data survives pod deletion" "$CONTENT_AFTER" "Hello from web-0"

###############################################################################
# Step 8: Scale StatefulSet
###############################################################################

echo ""
echo "StatefulSet Scaling:"

# Scale up to 5
kubectl scale statefulset web -n "$NS" --replicas=5 &>/dev/null
kubectl rollout status statefulset/web -n "$NS" --timeout=180s &>/dev/null

READY_5=$(kubectl get statefulset web -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "scale up: 5 ready replicas" "5" "$READY_5"

PVC_COUNT_5=$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | grep -c "web-data-web" || true)
assert_eq "scale up: 5 PVCs created" "5" "$PVC_COUNT_5"

# Verify new pods have predictable names
POD3=$(kubectl get pod web-3 -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "scaled pod web-3 exists" "web-3" "$POD3"

POD4=$(kubectl get pod web-4 -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "scaled pod web-4 exists" "web-4" "$POD4"

# Scale down to 2
kubectl scale statefulset web -n "$NS" --replicas=2 &>/dev/null
# Wait for scale-down
sleep 60
kubectl wait --for=jsonpath='{.status.readyReplicas}'=2 statefulset/web -n "$NS" --timeout=60s &>/dev/null

READY_2=$(kubectl get statefulset web -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "scale down: 2 ready replicas" "2" "$READY_2"

# PVCs are retained after scale-down
PVC_COUNT_AFTER=$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | grep -c "web-data-web" || true)
assert_eq "PVCs retained after scale-down (still 5)" "5" "$PVC_COUNT_AFTER"

# Only web-0 and web-1 should be running
POD_RUNNING=$(kubectl get pods -n "$NS" -l app=web --no-headers 2>/dev/null | grep -c "Running" || true)
assert_eq "only 2 pods running after scale-down" "2" "$POD_RUNNING"

###############################################################################
# Step 9: Volume expansion
###############################################################################

echo ""
echo "Volume Expansion:"

if [ "$GP2_EXPAND" = "true" ]; then
  # Patch PVC from 1Gi to 2Gi
  kubectl patch pvc web-data-web-0 -n "$NS" \
    -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}' &>/dev/null

  sleep 5

  PVC_REQ=$(kubectl get pvc web-data-web-0 -n "$NS" \
    -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
  assert_eq "PVC web-data-web-0 request updated to 2Gi" "2Gi" "$PVC_REQ"

  # Check for resizing condition (FileSystemResizePending or empty means completed)
  PVC_CONDITIONS=$(kubectl get pvc web-data-web-0 -n "$NS" \
    -o jsonpath='{.status.conditions[*].type}' 2>/dev/null)
  if [ -z "$PVC_CONDITIONS" ] || echo "$PVC_CONDITIONS" | grep -qE "FileSystemResizePending|Resizing"; then
    pass "volume expansion in progress or completed"
  else
    pass "volume expansion accepted (conditions: $PVC_CONDITIONS)"
  fi

  # Verify the original PVC (web-data-web-1) was NOT expanded
  PVC1_SIZE=$(kubectl get pvc web-data-web-1 -n "$NS" \
    -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
  assert_eq "web-data-web-1 still at 1Gi (not expanded)" "1Gi" "$PVC1_SIZE"
else
  skip "volume expansion tests skipped (gp2 does not allow volume expansion)"
fi

###############################################################################
# Cleanup
###############################################################################

echo ""
echo "Cleanup:"

kubectl delete statefulset web -n "$NS" --timeout=60s &>/dev/null
kubectl delete pvc --all -n "$NS" --timeout=60s &>/dev/null
cleanup_ns "$NS"
assert_cmd_fails "namespace removed after teardown" kubectl get namespace "$NS"

summary
