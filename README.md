# Istio Ambient Mesh Lab

Sidecar-less service mesh with Istio Ambient mode (ztunnel + waypoint proxies) on a multi-node kind cluster.

## Steps
- [x] 00 - Multi-node kind cluster
- [ ] 01 - Istio ambient install + Prometheus/Grafana/Kiali
- [ ] 02 - Workloads in ambient mesh (mTLS proof)
- [ ] 03 - Waypoint proxy + HTTPRoute 80/20 canary
- [ ] 04 - L4 vs L7 AuthorizationPolicy
- [ ] 05 - Resource overhead comparison (ambient vs sidecar)
- [ ] 06 - Failure tests (ztunnel, waypoint)
- [ ] Docs - architecture diagram + blast-radius analysis
