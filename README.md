# Istio Ambient Mesh Lab

Sidecar-less service mesh with Istio 1.31.1 ambient mode (ztunnel + waypoint proxy) on a 3-node kind cluster, compared hands-on against sidecar mode.

Details, numbers and caveats: [docs/FINDINGS.md](docs/FINDINGS.md). Diagrams: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Raw outputs: `evidence/`.

## Key results

- Joining the mesh was a namespace label: no pod restart, one container per pod, mTLS via ztunnel. Node-level capture showed HBONE on port 15008 and no plaintext app traffic.
- L7 was opt-in: a waypoint was attached to one Service (`reviews`) only. An HTTPRoute split its traffic 80/20 (measured v1=78, v2=22).
- L4 policy (ztunnel): connection reset, no HTTP exchange. L7 policy (waypoint): HTTP 403 on `/admin`. The L7 policy is skipped for traffic sent straight to a pod IP.
- Proxy containers for 13 app pods: 4 in ambient (3 ztunnel + 1 waypoint) vs 13 sidecars. Actual memory under load: about 76Mi vs 458Mi. Actual CPU was not lower in ambient at this scale.
- Killing a ztunnel broke only paths with a pod on that node (about one probe interval, 3 runs). Killing the waypoint made its Service fail for about 2-3s while other Services were unaffected.

## Layout

| Path | Content |
|---|---|
| `00-cluster/` | kind config (1 control-plane + 2 workers) |
| `01-istio-install/` | `install.sh` (Gateway API CRDs + ambient profile), `addons.sh` |
| `02-workloads/` | Bookinfo + curl manifests |
| `03-waypoint/` | waypoint Gateway, per-version Services, HTTPRoute 80/20, `test-split.sh` |
| `04-authz/` | L4 and L7 AuthorizationPolicies |
| `05-overhead/` | `measure.sh`, `rollout-test.sh` |
| `06-failure-tests/` | probe pods, `ztunnel-kill.sh`, `waypoint-kill.sh` |
| `docs/`, `evidence/` | write-up and raw outputs |

## Reproduce

```bash
kind create cluster --config 00-cluster/kind-config.yaml
./01-istio-install/install.sh && ./01-istio-install/addons.sh
kubectl create namespace ambient-demo
kubectl apply -n ambient-demo -f 02-workloads/
kubectl label namespace ambient-demo istio.io/dataplane-mode=ambient
kubectl apply -f 03-waypoint/waypoint.yaml
kubectl label service reviews -n ambient-demo istio.io/use-waypoint=waypoint
kubectl apply -f 03-waypoint/reviews-versions.yaml -f 03-waypoint/reviews-httproute-80-20.yaml
kubectl apply -f 04-authz/
# sidecar comparison namespace
kubectl create namespace sidecar-demo && kubectl label namespace sidecar-demo istio-injection=enabled
kubectl apply -n sidecar-demo -f 02-workloads/
# failure tests need their own ambient namespace
kubectl create namespace failure-demo && kubectl label namespace failure-demo istio.io/dataplane-mode=ambient
```

`02-workloads/` and `05-overhead/` scripts expect metrics-server (`--kubelet-insecure-tls` on kind) and Istio 1.31.1 sample addons under `~/istio-1.31.1`.
