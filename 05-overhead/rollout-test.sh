#!/usr/bin/env bash
set -uo pipefail

show() {  # args: kubectl get pods selectors
  kubectl get pods "$@" -o custom-columns=NAME:.metadata.name,INIT:.spec.initContainers[*].name,CONTAINERS:.spec.containers[*].name,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.startTime
}
codes() {  # $1 = namespace
  for i in $(seq 1 10); do
    kubectl exec -n "$1" deploy/curl -- curl -s -o /dev/null -w "%{http_code} " http://productpage:9080/productpage
  done; echo
}

echo "##### A. AMBIENT: restart one APP deployment, ztunnel must stay untouched #####"
echo "-- ztunnel BEFORE --";  show -n istio-system -l app=ztunnel
kubectl rollout restart -n ambient-demo deploy/productpage-v1
kubectl rollout status  -n ambient-demo deploy/productpage-v1 --timeout=180s
echo "-- ztunnel AFTER --";   show -n istio-system -l app=ztunnel
echo "-- productpage pods (ambient) --"; show -n ambient-demo -l app=productpage

echo
echo "##### B. SIDECAR: restart same app deployment, proxy is recreated with the pod #####"
echo "-- productpage pods BEFORE --"; show -n sidecar-demo -l app=productpage
kubectl rollout restart -n sidecar-demo deploy/productpage-v1
kubectl rollout status  -n sidecar-demo deploy/productpage-v1 --timeout=180s
echo "-- productpage pods AFTER (new pods, new istio-proxy each) --"; show -n sidecar-demo -l app=productpage
echo "-- proxy image is baked into every app pod: --"
kubectl get pods -n sidecar-demo -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.initContainers[?(@.name=="istio-proxy")].image}{"\n"}{end}'

echo
echo "##### C. AMBIENT: restart ALL ztunnels (data-plane restart), app pods untouched #####"
echo "-- ambient app pods BEFORE --"; show -n ambient-demo
kubectl rollout restart -n istio-system ds/ztunnel
kubectl rollout status  -n istio-system ds/ztunnel --timeout=180s
sleep 10
echo "-- ambient app pods AFTER (names, RESTARTS, STARTED must be unchanged) --"; show -n ambient-demo
echo "-- traffic after ztunnel restart (10 requests) --"; codes ambient-demo

echo
echo "##### D. waypoint resource requests (missing from the overhead table) #####"
kubectl get deploy waypoint -n ambient-demo -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo
