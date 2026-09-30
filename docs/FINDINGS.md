# Findings

All numbers below come from the files in `evidence/`. Anything not measured is listed under "Not done / caveats".

## 1. Environment

- kind v0.30.0, Kubernetes v1.34.0, 3 nodes (1 control-plane, 2 workers)
- Istio 1.31.1, `istioctl install --set profile=ambient` (istiod, istio-cni, ztunnel)
- Gateway API CRDs v1.4.0 (standard install)
- Prometheus, Grafana, Kiali from the Istio 1.31.1 sample addons; metrics-server (`--kubelet-insecure-tls`) for `kubectl top`
- Host: 12 CPUs, ~14Gi RAM, shared with the desktop
- Workload: Istio Bookinfo (productpage, details, ratings, reviews v1/v2/v3) plus a curl client

## 2. Joining the mesh: no restart, no sidecar, mTLS via ztunnel

- Namespace `ambient-demo` was deployed first without the mesh, then labeled `istio.io/dataplane-mode=ambient`. Pod AGE stayed continuous, RESTARTS stayed 0, READY stayed 1/1 (`02-pods-before-ambient.txt`, `02-pods-after-ambient.txt`).
- The productpage pod has exactly one container, `productpage` (`02-container-names.txt`).
- `istioctl ztunnel-config workload` lists every workload with protocol HBONE (`02-ztunnel-workloads.txt`).
- ztunnel access logs show SPIFFE identities `.../sa/curl` -> `.../sa/bookinfo-productpage` with `dst.hbone_addr` on port 15008 (`02-ztunnel-logs.txt`).
- Packet capture on the kind Docker bridge (`02-packet-capture.txt`): 12834 packets total, 423 on port 15008 (curl pod on ambient-worker to productpage on ambient-worker2), 0 packets on port 9080, 0 occurrences of the plaintext page text. The capture only sees cross-node traffic, and this pair was on different nodes.

## 3. Selective L7: waypoint for one Service, 80/20 canary

- Waypoint Gateway created in `ambient-demo`, then only the `reviews` Service got `istio.io/use-waypoint=waypoint`. `istioctl ztunnel-config service` shows the waypoint on `reviews` and `None` on details, productpage, ratings and curl (`03-ztunnel-services-waypoint.txt`). One waypoint pod was added; no other pod changed (`03-pods-with-waypoint.txt`).
- 100 requests to `reviews` before any route: v1=33, v2=28, v3=39 (`03-split-before-route.txt`).
- After an HTTPRoute with weights 80 (reviews-v1) and 20 (reviews-v2): v1=78, v2=22, v3=0 (`03-split-after-route-80-20.txt`).

## 4. L4 vs L7 authorization

- Baseline: details 200, /reviews/0 200, /admin 404 from the app (`04-baseline-before-policies.txt`).
- L4 policy on `details` (only the productpage identity allowed), enforced by ztunnel: from the curl identity the connection is reset, `curl: (56) Connection reset by peer`, http_code 000, no HTTP exchange. productpage still returns 200 (`04-l4-test.txt`). The task text says "connection refused"; ztunnel actually resets the connection.
- L7 policy on `reviews` (GET on /reviews/* and /health only), enforced by the waypoint: /reviews/0 returns 200, /admin returns 403 with body `RBAC: access denied`, the connection itself succeeds (`04-l7-test.txt`).
- Limitation: sending the same `/admin` request straight to a reviews pod IP returns 404 (the app's answer) instead of 403, so the waypoint policy is skipped on that path (`06-waypoint-bypass-check.txt`). A mitigation (an L4 policy that only allows the waypoint identity) was not tested here.

## 5. Resource overhead (same cluster, same Bookinfo images, 800 sequential requests per model)

Sidecar mode ran in a second namespace (`sidecar-demo`, `istio-injection=enabled`) in the same cluster, because no earlier sidecar setup existed.

| | Ambient, 7 pods | Sidecar, 7 pods | Ambient, 13 pods | Sidecar, 13 pods |
|---|---|---|---|---|
| Proxy containers | 4 (3 ztunnel + 1 waypoint) | 7 | 4 | 13 |
| Actual memory under load | 80Mi (43 + 37) | 237Mi | 76Mi (40 + 36) | 458Mi |
| Actual CPU under load | 244m (200 + 44) | 204m | 341m (277 + 64) | 228m |
| Reserved CPU (requests) | 700m | 700m | 700m | 1300m |
| Reserved memory (requests) | 1664Mi | 896Mi | 1664Mi | 1664Mi |

Requests used: ztunnel 200m / 512Mi per node (3 nodes), waypoint 100m / 128Mi, sidecar 100m / 128Mi per pod. Files: `05-overhead-7pods.txt`, `05-overhead-13pods.txt`, `05-sidecar-pods.txt`.

Reading the numbers:
- Proxy count and actual memory scale with pods in sidecar mode (about 35Mi per extra sidecar) and stay flat in ambient mode.
- Ambient has a fixed per-node cost. At 7 pods it reserves more memory than sidecars; the reserved memory is equal at 13 pods, and sidecars reserve more beyond that.
- Actual CPU was higher in ambient in every run. This is not evidence that ambient saves CPU at this scale. The load came from one client, and each figure is a single metrics-server snapshot.

## 6. Rollout / data-plane restart behavior (`05-rollout-test.txt`)

- Restarting an application Deployment in ambient mode left the three ztunnel pods untouched (same start time, RESTARTS 0).
- In sidecar mode every app pod carries its own `istio-proxy` (`docker.io/istio/proxyv2:1.31.1-distroless`), so changing the proxy means recreating the app pods.
- Restarting the whole ztunnel DaemonSet rolled 0/3 -> 3/3 with no app pod changed (names, RESTARTS and start times identical). 10 of 10 requests returned 200 after the rollout finished.
- This was a data-plane restart test, not a real Istio version upgrade.

## 7. Failure tests

### ztunnel killed on ambient-worker2 (3 runs, `06-ztunnel-kill-run1/2/3.txt`)

Four paths probed every ~0.4s: P1 both pods on ambient-worker; P2 both pods on ambient-worker2; P3 client on ambient-worker to server on ambient-worker2; P4 client on ambient-worker2 to server on ambient-worker.

| Run | P1 | P2 | P3 | P4 | Replacement Ready |
|---|---|---|---|---|---|
| 1 | 0 failed | 1 failed (0.3s) | 1 failed (0.3s) | 1 failed (0.3s) | 1.3s |
| 2 | 0 failed | 1 failed (0.4s) | 1 failed (0.4s) | 1 failed (0.4s) | 1.3s |
| 3 | 0 failed | 1 failed (0.3s) | 1 failed (0.3s) | 1 failed (0.3s) | 1.3s |

Blast radius: only paths with a pod on the affected node broke, each for about one probe interval. The path between the other two pods was untouched, and no application pod restarted.

### waypoint killed (`06-waypoint-kill-test.txt`)

| Probe | What it does | Result |
|---|---|---|
| W1 | curl to the `reviews` Service (through the waypoint) | 6 failures (000), 0.5s to 2.6s after the kill |
| W2 | curl to the `ratings` Service (no waypoint) | 0 failures |
| W3 | curl to productpage (calls reviews) | 6 degraded pages (200 with reviews unavailable), 0.3s to 2.6s |
| W4 | curl straight to a reviews pod IP (skips the waypoint) | 0 failures |

Replacement waypoint was Ready after 3.0s; no app pod or ztunnel restarted.

Conclusions: only the Service that has a waypoint was affected, and its dependents degraded instead of failing. The affected Service did not merely lose L7 features. Its connections failed, because the waypoint sits on the path of every request addressed to that Service. L4 mTLS through ztunnel kept working for traffic that does not go through the waypoint (W4).

## Not done / caveats

- Kiali's ambient-vs-sidecar view and Grafana dashboards were not compared. Resource numbers come from `kubectl top` (metrics-server), not Prometheus.
- The sidecar comparison shares a cluster with ambient mode instead of being a separate earlier setup. Scale stopped at 13 app pods. Anything beyond that is extrapolation and was not measured.
- Load was one client with sequential requests; CPU figures are single snapshots and noisy.
- ztunnel test covered new connections only, sampled about every 0.4s. Long-lived connections through a killed ztunnel were not tested. The waypoint ran as a single replica; more replicas were not tested.
- The failure probes ran in their own namespace (`failure-demo`). In `ambient-demo` after the Step 04 policies, ztunnel rejected them with "allow policies exist, but none allowed". That was not root-caused.
