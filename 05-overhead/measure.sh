#!/usr/bin/env bash
set -uo pipefail
REQS=${1:-800}

load() {  # $1 = namespace
  kubectl exec -n "$1" deploy/curl -- sh -c \
    "for i in \$(seq 1 $REQS); do curl -s -o /dev/null http://productpage:9080/productpage; done"
}

echo "##### 1. PROXY CONTAINER COUNT #####"
AMB_ZT=$(kubectl get pods -n istio-system --no-headers | grep -c '^ztunnel')
AMB_WP=$(kubectl get pods -n ambient-demo --no-headers | grep -c '^waypoint')
AMB_APP=$(kubectl get pods -n ambient-demo --no-headers | grep -vc '^waypoint')
SC_PODS=$(kubectl get pods -n sidecar-demo --no-headers | wc -l)
# istio-proxy is a native sidecar => lives in initContainers
SC_PROXY=$(kubectl get pods -n sidecar-demo -o jsonpath='{range .items[*]}{.spec.initContainers[*].name}{"\n"}{end}' | tr ' ' '\n' | grep -c '^istio-proxy$')
echo "AMBIENT : app pods=$AMB_APP | ztunnel=$AMB_ZT (1 per node) + waypoints=$AMB_WP => proxy containers=$((AMB_ZT+AMB_WP))"
echo "SIDECAR : app pods=$SC_PODS | istio-proxy sidecars=$SC_PROXY => proxy containers=$SC_PROXY"

echo
echo "##### 2. RESOURCE REQUESTS (what gets reserved) #####"
echo -n "sidecar istio-proxy (per pod) : "
kubectl get pod -n sidecar-demo -l app=productpage -o jsonpath='{.items[0].spec.initContainers[?(@.name=="istio-proxy")].resources}'; echo
echo -n "ztunnel (per node)            : "
kubectl get ds ztunnel -n istio-system -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo

echo
echo "##### 3. AMBIENT under load ($REQS requests) #####"
load ambient-demo
sleep 5
kubectl top pod -n istio-system --no-headers | awk '/^ztunnel/'
kubectl top pod -n ambient-demo --no-headers | awk '/^waypoint/'
kubectl top pod -n istio-system --no-headers | awk '/^ztunnel/{gsub("m","",$2);gsub("Mi","",$3);c+=$2;m+=$3} END{print "ztunnels total: cpu="c"m mem="m"Mi"}'
kubectl top pod -n ambient-demo --no-headers | awk '/^waypoint/{gsub("m","",$2);gsub("Mi","",$3);c+=$2;m+=$3} END{print "waypoints total: cpu="c"m mem="m"Mi"}'

echo
echo "##### 4. SIDECAR under load ($REQS requests) #####"
load sidecar-demo
sleep 5
kubectl top pod -n sidecar-demo --containers --no-headers | awk '$2=="istio-proxy"'
kubectl top pod -n sidecar-demo --containers --no-headers | awk '$2=="istio-proxy"{gsub("m","",$3);gsub("Mi","",$4);c+=$3;m+=$4} END{print "sidecars total: cpu="c"m mem="m"Mi"}'
