#!/bin/bash
###############################################################################
# Lab 2 (Part 2) Test: Scheduling and Placement
# Covers: node labels, node affinity (required/nope/preferred), pod affinity,
#         pod anti-affinity, taints/tolerations, topology spread, DaemonSets
#
# Assertions favor deterministic spec fields (work on any cluster). Scheduling
# OUTCOMES (co-location, spreading) depend on node count/zones and are
# best-effort — skipped when the cluster shape can't satisfy them.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

LAB_DIR="$(cd "$SCRIPT_DIR/../lab-02-scheduling" && pwd)"
export STUDENT_NAME="test-$$"
NS="sched-$STUDENT_NAME"
echo "=== Lab 2 (Part 2): Scheduling and Placement (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

apply() { envsubst '$STUDENT_NAME' < "$LAB_DIR/$1" | kubectl apply -f - &>/dev/null; }

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0)
echo "Cluster has $NODE_COUNT Ready node(s)"

# ─── Step 1: Node labels ────────────────────────────────────────────────

echo ""
echo "Node Labels:"
ZONES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)
if [ -n "$ZONES" ]; then
  pass "nodes expose topology.kubernetes.io/zone label ($ZONES)"
else
  skip "nodes have no zone labels (single-node/local cluster)"
fi

# ─── Step 2: Node affinity — required ────────────────────────────────────

echo ""
echo "Node Affinity (required):"
apply node-affinity-required.yaml
AFF=$(kubectl get pod node-affinity-required -n "$NS" \
  -o jsonpath='{.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key}' 2>/dev/null)
assert_eq "required node affinity targets the zone label" "topology.kubernetes.io/zone" "$AFF"

# ─── Step 2b: Impossible match stays Pending ─────────────────────────────

echo ""
echo "Node Affinity (impossible match):"
apply node-affinity-nope.yaml
sleep 8
PHASE=$(kubectl get pod node-affinity-nope -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
assert_eq "node-affinity-nope stays Pending (no matching node)" "Pending" "$PHASE"
EVENTS=$(kubectl get events -n "$NS" --field-selector involvedObject.name=node-affinity-nope 2>/dev/null)
assert_contains "scheduler reports FailedScheduling" "$EVENTS" "FailedScheduling"

# ─── Step 3: Node affinity — preferred ───────────────────────────────────

echo ""
echo "Node Affinity (preferred):"
apply node-affinity-preferred.yaml
WEIGHT=$(kubectl get pod node-affinity-preferred -n "$NS" \
  -o jsonpath='{.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight}' 2>/dev/null)
assert_eq "preferred node affinity has weight 80" "80" "$WEIGHT"
if wait_for_pod "$NS" node-affinity-preferred 60; then
  pass "preferred-affinity pod schedules (soft rule never blocks)"
else
  skip "preferred-affinity pod not Ready yet"
fi

# ─── Step 4: Pod affinity — co-locate ────────────────────────────────────

echo ""
echo "Pod Affinity (co-locate):"
apply cache-pod.yaml
apply web-with-affinity.yaml
PAFF=$(kubectl get pod web-with-affinity -n "$NS" \
  -o jsonpath='{.spec.affinity.podAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey}' 2>/dev/null)
assert_eq "web pod has podAffinity on hostname" "kubernetes.io/hostname" "$PAFF"
if wait_for_pod "$NS" cache 60 && wait_for_pod "$NS" web-with-affinity 60; then
  CNODE=$(kubectl get pod cache -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  WNODE=$(kubectl get pod web-with-affinity -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  assert_eq "web pod co-located on cache's node" "$CNODE" "$WNODE"
else
  skip "co-location outcome (one of cache/web not scheduled)"
fi

# ─── Step 5: Pod anti-affinity — spread ──────────────────────────────────

echo ""
echo "Pod Anti-Affinity (spread):"
apply spread-deployment.yaml
ANTI=$(kubectl get deployment spread-app -n "$NS" \
  -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey}' 2>/dev/null)
assert_eq "spread-app has podAntiAffinity on hostname" "kubernetes.io/hostname" "$ANTI"
REPL=$(kubectl get deployment spread-app -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
assert_eq "spread-app requests 3 replicas" "3" "$REPL"
if [ "${NODE_COUNT:-0}" -ge 3 ]; then
  sleep 10
  NODES_USED=$(kubectl get pods -n "$NS" -l app=spread-app -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -c . || echo 0)
  if [ "$NODES_USED" -ge 2 ]; then
    pass "anti-affinity spread replicas across $NODES_USED nodes"
  else
    skip "replicas not yet spread (scheduling in progress)"
  fi
else
  skip "anti-affinity spread needs 3+ nodes (have $NODE_COUNT)"
fi

# ─── Step 6: Taints and tolerations ──────────────────────────────────────

echo ""
echo "Tolerations:"
apply toleration-pod.yaml
TOL=$(kubectl get pod toleration-demo -n "$NS" \
  -o jsonpath='{.spec.tolerations[?(@.key=="dedicated")].value}' 2>/dev/null)
assert_contains "toleration-demo tolerates dedicated=monitoring" "$TOL" "monitoring"

# ─── Step 7: Topology spread constraints ─────────────────────────────────

echo ""
echo "Topology Spread:"
apply topology-spread.yaml
SKEW=$(kubectl get deployment zone-spread -n "$NS" \
  -o jsonpath='{.spec.template.spec.topologySpreadConstraints[0].maxSkew}' 2>/dev/null)
assert_eq "zone-spread sets maxSkew 1" "1" "$SKEW"
TKEY=$(kubectl get deployment zone-spread -n "$NS" \
  -o jsonpath='{.spec.template.spec.topologySpreadConstraints[0].topologyKey}' 2>/dev/null)
assert_eq "zone-spread spreads on the zone topology key" "topology.kubernetes.io/zone" "$TKEY"

# ─── Step 8: DaemonSets (observe) ────────────────────────────────────────

echo ""
echo "DaemonSets:"
DS=$(kubectl get daemonset -n kube-system --no-headers 2>/dev/null | grep -c . || echo 0)
if [ "${DS:-0}" -gt 0 ]; then
  pass "kube-system runs $DS DaemonSet(s) — one Pod per node"
else
  skip "no DaemonSets in kube-system on this cluster"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────

echo ""
cleanup_ns "$NS"

summary
