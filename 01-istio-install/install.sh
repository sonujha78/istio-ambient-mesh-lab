#!/usr/bin/env bash
set -euo pipefail

# 1. Gateway API CRDs (needed for waypoint + HTTPRoute)
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
  kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

# 2. Istio ambient profile (istiod + istio-cni + ztunnel)
istioctl install --set profile=ambient --skip-confirmation
