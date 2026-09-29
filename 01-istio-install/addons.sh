#!/usr/bin/env bash
set -euo pipefail

ADDONS_DIR="${ISTIO_DIR:-$HOME/istio-1.31.1}/samples/addons"

kubectl apply -f "$ADDONS_DIR/prometheus.yaml"
kubectl apply -f "$ADDONS_DIR/grafana.yaml"
kubectl apply -f "$ADDONS_DIR/kiali.yaml"

kubectl -n istio-system rollout status deploy/prometheus --timeout=180s
kubectl -n istio-system rollout status deploy/grafana --timeout=180s
kubectl -n istio-system rollout status deploy/kiali --timeout=180s
