# Deployment: Proxmox Monitoring

## Context

Add Proxmox host monitoring to the existing observability stack to provide visibility into the Proxmox host (`pve2.lan.balti.casa`) that runs the k3s cluster. This extends the current Prometheus + Grafana deployment with a Proxmox exporter, enabling operational monitoring of host resources, VM status, and storage health.

The deployment integrates seamlessly with the existing GitOps-managed observability infrastructure in the `observability/` realm, following established patterns for secret management (Vault + Vals), metrics collection (Prometheus Operator + ServiceMonitor), and dashboard provisioning (Grafana).

## Deployment Stories

### Story 1: Deploy Proxmox Exporter

**As a** platform operator,  
**I want to** deploy a Proxmox exporter that collects metrics from `pve2.lan.balti.casa`,  
**So that** I have visibility into the Proxmox host's resource usage, VM status, and health.

#### Acceptance Criteria
- [ ] Proxmox exporter deployed in `observability` namespace via Helmfile
- [ ] Exporter authenticates to Proxmox API using credentials from Vault (`kv/observability/proxmox-exporter`)
- [ ] Exporter exposes metrics on a standard port (typically 9221)
- [ ] Deployment includes appropriate resource requests/limits
- [ ] Health checks configured (liveness/readiness probes)

#### Expected Behavior

- Exporter runs as a Deployment (single replica is sufficient for one Proxmox host)
- On startup, authenticates to `pve2.lan.balti.casa` using Vault-injected credentials
- Continuously polls Proxmox API and exposes metrics in Prometheus format
- Metrics include: host CPU/memory/disk, VM status, storage pool usage, cluster health

#### Edge Cases & Failures

- **Proxmox API unreachable**: Exporter continues running, exposes stale metrics with timestamps, logs errors
- **Invalid credentials**: Exporter fails health checks, ArgoCD shows degraded state
- **Proxmox host reboot**: Exporter reconnects automatically when API becomes available
- **During ArgoCD sync**: Zero-downtime not critical (brief metrics gap acceptable)

---

### Story 2: Configure Prometheus Scraping

**As a** platform operator,  
**I want to** configure Prometheus to scrape the Proxmox exporter,  
**So that** Proxmox metrics are collected and queryable in Prometheus.

#### Acceptance Criteria
- [ ] ServiceMonitor created for Proxmox exporter (Prometheus Operator pattern)
- [ ] Scrape interval matches other infrastructure exporters (30s-60s)
- [ ] Metrics labeled appropriately (`job="proxmox"`, `instance="pve2.lan.balti.casa"`)
- [ ] Prometheus successfully discovers and scrapes the target

#### Expected Behavior

- Prometheus Operator detects ServiceMonitor, updates scrape configuration
- Metrics appear in Prometheus within one scrape interval
- Target shows as "up" in Prometheus targets UI

#### Edge Cases & Failures

- **ServiceMonitor selector mismatch**: Target won't be discovered (validate label matching during implementation)
- **Exporter down**: Prometheus marks target as "down", existing metrics retained per retention policy
- **Prometheus restart**: Scraping resumes automatically after pod becomes ready

---

### Story 3: Provision Grafana Dashboards

**As a** platform operator,  
**I want to** pre-configured Grafana dashboards for Proxmox metrics,  
**So that** I can visualize host health, VM status, and resource trends without manual dashboard creation.

#### Acceptance Criteria
- [ ] Grafana dashboard ConfigMap or sidecar pattern configured
- [ ] Dashboard shows: host CPU/memory/disk usage, VM status overview, storage pool utilization
- [ ] Dashboard uses existing Prometheus datasource (not a new datasource)
- [ ] Dashboard accessible via existing Grafana ingress (Gateway API HTTPRoute)

#### Expected Behavior

- Dashboard appears automatically in Grafana after deployment (via sidecar or ConfigMap)
- All panels query Prometheus successfully
- Dashboard organizes metrics logically (host overview, per-VM details, storage)

#### Edge Cases & Failures

- **Dashboard references non-existent metrics**: Panels show "No data" (not a failure, exporter may need time)
- **Grafana restart**: Dashboards reload from ConfigMap/sidecar
- **Dashboard updates**: Changes applied on next Grafana sync/restart

---

## GitOps Structure

```
infrastructure/observability/proxmox-exporter/
├── helmfile.yaml          # Helm release for Proxmox exporter chart
├── values.yaml            # Helm values with Vals secret injection
└── resources/
    ├── servicemonitor.yaml    # Prometheus Operator ServiceMonitor
    └── dashboard-configmap.yaml # Grafana dashboard (if using ConfigMap method)
```

**Helmfile pattern:**
- Uses upstream Prometheus Proxmox Exporter chart (e.g., `prometheus-community/prometheus-pve-exporter`)
- Vals injects credentials from `kv/observability/proxmox-exporter` into Helm values
- ServiceMonitor created as additional manifest in `resources/`
- Grafana dashboard provisioned via ConfigMap or sidecar pattern (depending on existing Grafana configuration)

**ArgoCD integration:**
- Picked up automatically by existing `infrastructure/*/*` ApplicationSet
- Syncs to `observability` namespace
- Standard retry logic and server-side apply

## Environment Strategy

Single environment (production cluster). No dev/staging differentiation needed — this monitors the production Proxmox host.

## Consistency Notes

- **Realm pattern**: Deployed in `observability/` realm alongside Prometheus, Grafana, metrics-server
- **Secret management**: Follows Vault + Vals pattern consistent with cert-manager, external-dns, democratic-csi
- **Prometheus integration**: Uses ServiceMonitor pattern for scrape configuration
- **Namespace convention**: Uses `observability` namespace, created via `CreateNamespace=true` in Helmfile
- **Resource limits**: Defines CPU/memory requests and limits per platform convention

## Implementation Remarks

### Architecture & Security (Kai)

- **Exporter placement**: Standard Pod deployment sufficient (no node affinity or host networking required) — this scrapes an external Proxmox host
- **Network policy**: Exporter requires egress to `pve2.lan.balti.casa` port 8006 (Proxmox API). Verify Cilium network policies allow this traffic.
- **Service mesh**: If using Cilium service mesh features, ensure outbound Proxmox API calls aren't blocked by policy
- **Secret security**: Proxmox API credentials grant VM management access — treat as highly sensitive. Vault injection is appropriate. Ensure ServiceAccount has minimal RBAC (only needs to run, not access K8s API).
- **Resource constraints**: Proxmox exporter is lightweight but set limits to prevent runaway queries:
  - Recommended: `requests: 50m CPU / 64Mi memory, limits: 200m CPU / 128Mi memory`
- **Multi-host scalability**: Currently targets one Proxmox host. If adding more later, design Helmfile values structure to support multiple exporter instances or a single exporter with multiple targets.

### Operational Considerations (Jordan)

- **Secret bootstrap**: Before first deployment, populate Vault `kv/observability/proxmox-exporter` with authentication credentials:
  - **Preferred**: Token-based auth (`PROXMOX_TOKEN_ID`, `PROXMOX_SECRET`) — more secure and auditable
  - **Alternative**: User/password auth (`PROXMOX_USER`, `PROXMOX_PASSWORD`)
  - Document the chosen auth method and credential format
- **Credential rotation**: When Proxmox credentials change:
  1. Update Vault secret
  2. Run `argocd app sync observability-proxmox-exporter` to refresh deployment
  3. Document this procedure in component README
- **Dashboard provisioning method**: Choose based on existing Grafana configuration:
  - **Sidecar pattern** (kiwigrid/k8s-sidecar): Dashboards in ConfigMaps with specific labels, sidecar watches and loads them — flexible, GitOps-friendly
  - **ConfigMap volume mount**: Direct mount into Grafana — simpler, requires Grafana restart for updates
  - Recommend sidecar if already in use; otherwise ConfigMap volume mount is simpler for a single dashboard
- **ServiceMonitor namespace**: Ensure ServiceMonitor is in `observability` namespace and Prometheus Operator is configured to watch it (likely already configured)
- **Proxmox API authentication**: Multiple auth modes available (user/password, API tokens, ticket-based). API tokens are preferred — ensure Helmfile values support the chosen method cleanly.
- **Observability of observability**: Consider Prometheus alerting rule to detect exporter failures:
  ```yaml
  alert: ProxmoxExporterDown
  expr: up{job="proxmox"} == 0
  for: 5m
  ```

## Open Questions

None — intent is clear and design is complete. Ready for implementation phase.
