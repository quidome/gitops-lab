# Story: Prometheus and Grafana Observability Stack

**Design Spec**: [~/store/gitops-designs/2026-02-22-prometheus-grafana-observability.md](file:///home/quidome/store/gitops-designs/2026-02-22-prometheus-grafana-observability.md)
**Status**: Pending
**Created**: 2026-02-22

## Objective

Deploy a modular Prometheus and Grafana observability stack to provide centralized cluster metrics collection and visualization, enabling fast detection of pod failures, resource exhaustion, and cluster health issues.

## Functional Requirements Summary

From the design spec (3 deployment stories):

1. **Prometheus for metrics collection**: Deploy Prometheus server to scrape and store cluster/infrastructure metrics (node, pod, container, API server) with 30-day retention on persistent storage.

2. **Grafana for visualization**: Deploy Grafana with pre-configured Prometheus data source and community dashboards for cluster monitoring, enabling quick visibility into pod health and resource usage.

3. **GitOps deployment**: Deploy all components via ArgoCD using Helmfile, following established platform patterns (manual sync, Vault secrets, persistent storage).

**Success criteria**: Operator can open Grafana dashboard and immediately answer "Are all pods running?", "Is anything hitting resource limits?", "Is the cluster healthy?" without running kubectl commands.

## Current State

**Existing:**
- `infrastructure/observability/metrics-server/` - Basic metrics for HPA (CPU/memory)
- ArgoCD ApplicationSet auto-discovers `infrastructure/*/*` patterns
- Manual sync policy for all infrastructure components
- Vault + Vals pattern for secret injection
- Gateway API HTTPRoute pattern for external access
- democratic-csi NFS storage class for persistent volumes

**What doesn't exist:**
- No centralized metrics storage (historical data)
- No visualization layer (dashboards)
- No cluster-wide observability (manual namespace checking required)

## Design

### Phase 1: Deploy Metrics Exporters

**Goal**: Deploy node-exporter and kube-state-metrics to provide metrics sources for Prometheus

**Scope**: Create two new Helmfile-managed components in `infrastructure/observability/`

#### Changes

**Create `infrastructure/observability/node-exporter/helmfile.yaml`:**
```yaml
repositories:
  - name: prometheus-community
    url: https://prometheus-community.github.io/helm-charts

releases:
  - name: prometheus-node-exporter
    namespace: observability
    chart: prometheus-community/prometheus-node-exporter
    version: 4.39.0
    values:
      - values.yaml
```

**Create `infrastructure/observability/node-exporter/values.yaml`:**
```yaml
# DaemonSet configuration
hostNetwork: true
hostPID: true

# Resource limits
resources:
  limits:
    cpu: 100m
    memory: 50Mi
  requests:
    cpu: 50m
    memory: 30Mi

# Prometheus scrape annotations
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9100"

# Service for Prometheus to discover
service:
  type: ClusterIP
  port: 9100
```

**Create `infrastructure/observability/kube-state-metrics/helmfile.yaml`:**
```yaml
repositories:
  - name: prometheus-community
    url: https://prometheus-community.github.io/helm-charts

releases:
  - name: kube-state-metrics
    namespace: observability
    chart: prometheus-community/kube-state-metrics
    version: 5.25.1
    values:
      - values.yaml
```

**Create `infrastructure/observability/kube-state-metrics/values.yaml`:**
```yaml
# Single replica (no HA needed)
replicas: 1

# Resource limits
resources:
  limits:
    cpu: 100m
    memory: 128Mi
  requests:
    cpu: 50m
    memory: 64Mi

# Prometheus scrape annotations
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"

# Service for Prometheus to discover
service:
  type: ClusterIP
  port: 8080
```

**Deployment:**
```bash
git add infrastructure/observability/node-exporter/
git add infrastructure/observability/kube-state-metrics/
git commit -m "feat(observability): add node-exporter and kube-state-metrics"
git push

# ArgoCD will detect new applications (within 3 minutes)
argocd app list | grep observability

# Sync applications
argocd app sync observability-node-exporter
argocd app sync observability-kube-state-metrics
```

#### Validations

```bash
# Health checks
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-node-exporter -n observability --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kube-state-metrics -n observability --timeout=120s

# Verify DaemonSet (node-exporter on all nodes)
NODES=$(kubectl get nodes --no-headers | wc -l)
NODE_EXP_PODS=$(kubectl get pods -n observability -l app.kubernetes.io/name=prometheus-node-exporter --no-headers | wc -l)
[ "$NODES" -eq "$NODE_EXP_PODS" ] && echo "✓ node-exporter on all nodes" || echo "✗ Missing node-exporter pods"

# Verify services exist
kubectl get svc -n observability prometheus-node-exporter
kubectl get svc -n observability kube-state-metrics
```

---

### Phase 2: Deploy Prometheus

**Goal**: Deploy Prometheus server to collect and store metrics from exporters

**Scope**: Create Prometheus Helmfile configuration with persistent storage and scrape config

#### Changes

**Create `infrastructure/observability/prometheus/helmfile.yaml`:**
```yaml
repositories:
  - name: prometheus-community
    url: https://prometheus-community.github.io/helm-charts

releases:
  - name: prometheus
    namespace: observability
    chart: prometheus-community/prometheus
    version: 25.27.0
    values:
      - values.yaml
```

**Create `infrastructure/observability/prometheus/values.yaml`:**
```yaml
server:
  # Persistent storage
  persistentVolume:
    enabled: true
    size: 15Gi
    storageClass: "democratic-csi-nfs"

  # Resource limits
  resources:
    limits:
      cpu: 500m
      memory: 1Gi
    requests:
      cpu: 250m
      memory: 500Mi

  # Retention configuration
  retention: "30d"

  # Global scrape configuration
  global:
    scrape_interval: 60s
    scrape_timeout: 10s
    evaluation_interval: 60s

  # Service type (internal only)
  service:
    type: ClusterIP

# Disable components deployed separately
alertmanager:
  enabled: false

nodeExporter:
  enabled: false

kubeStateMetrics:
  enabled: false

pushgateway:
  enabled: false
```

**Note**: The Prometheus chart auto-discovers scrape targets via Kubernetes service discovery. If auto-discovery fails, explicit scrape configs can be added in a follow-up.

**Deployment:**
```bash
git add infrastructure/observability/prometheus/
git commit -m "feat(observability): add Prometheus metrics server"
git push

# Sync after ArgoCD detects
argocd app sync observability-prometheus
```

#### Validations

```bash
# Health check
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n observability --timeout=180s

# PVC bound
kubectl get pvc -n observability prometheus-server -o jsonpath='{.status.phase}' | grep -q "Bound" && echo "✓ PVC bound"

# Verify scrape targets
kubectl port-forward -n observability svc/prometheus-server 9090:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5
echo "Active scrape targets:"
curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.health == "up") | .labels.job'
# Expected: node-exporter, kube-state-metrics, kubernetes-nodes, kubernetes-apiservers, prometheus
kill $PF_PID

# Verify metrics data available
kubectl port-forward -n observability svc/prometheus-server 9090:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5
NODE_METRICS=$(curl -s 'http://localhost:9090/api/v1/query?query=node_cpu_seconds_total' | jq -r '.data.result | length')
POD_METRICS=$(curl -s 'http://localhost:9090/api/v1/query?query=kube_pod_info' | jq -r '.data.result | length')
echo "Node metrics series: $NODE_METRICS"
echo "Pod metrics series: $POD_METRICS"
kill $PF_PID
```

---

### Phase 3: Deploy Grafana

**Goal**: Deploy Grafana with Prometheus data source, pre-configured dashboards, and HTTPRoute for external access

**Scope**: Create Grafana Helmfile configuration with Vals secret injection and HTTPRoute resource

#### Changes

**Create `infrastructure/observability/grafana/helmfile.yaml.gotmpl`:**
```yaml
repositories:
  - name: grafana
    url: https://grafana.github.io/helm-charts

releases:
  - name: grafana
    namespace: observability
    chart: grafana/grafana
    version: 8.5.2
    values:
      - values.yaml
      - adminPassword: {{ fetchSecretValue "ref+vault://kv/observability/grafana#admin-password" | quote }}

  # HTTPRoute as local chart
  - name: grafana-resources
    namespace: observability
    chart: ./resources
```

**Create `infrastructure/observability/grafana/values.yaml`:**
```yaml
# Admin credentials (password injected via Vals)
adminUser: admin

# Persistent storage
persistence:
  enabled: true
  size: 5Gi
  storageClass: "democratic-csi-nfs"

# Resource limits
resources:
  limits:
    cpu: 200m
    memory: 300Mi
  requests:
    cpu: 100m
    memory: 200Mi

# Service configuration
service:
  type: ClusterIP
  port: 80

# Data source provisioning (Prometheus)
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://prometheus-server.observability.svc.cluster.local:80
        access: proxy
        isDefault: true
        editable: false

# Dashboard provisioning
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default

# Community dashboards (auto-import)
dashboards:
  default:
    kubernetes-cluster:
      gnetId: 315
      revision: 3
      datasource: Prometheus
    node-exporter:
      gnetId: 1860
      revision: 31
      datasource: Prometheus
    kubernetes-pods:
      gnetId: 6417
      revision: 1
      datasource: Prometheus

# Grafana configuration
grafana.ini:
  server:
    root_url: https://grafana.quido.me
  security:
    admin_user: admin
```

**Create `infrastructure/observability/grafana/resources/Chart.yaml`:**
```yaml
apiVersion: v2
name: grafana-resources
description: Additional resources for Grafana (HTTPRoute)
version: 0.1.0
```

**Create `infrastructure/observability/grafana/resources/templates/http-route.yaml`:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: observability
spec:
  parentRefs:
    - name: gateway-internal
      namespace: networking
      group: gateway.networking.k8s.io
      kind: Gateway
  hostnames:
    - grafana.quido.me
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: grafana
          port: 80
          weight: 1
          group: ''
          kind: Service
```

**Note**: To switch to `gateway-external` later, change line `name: gateway-internal` to `name: gateway-external`.

**Deployment:**
```bash
git add infrastructure/observability/grafana/
git commit -m "feat(observability): add Grafana visualization"
git push

# Sync after ArgoCD detects
argocd app sync observability-grafana
```

#### Validations

```bash
# Health check
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n observability --timeout=180s

# PVC bound
kubectl get pvc -n observability grafana -o jsonpath='{.status.phase}' | grep -q "Bound" && echo "✓ PVC bound"

# HTTPRoute created
kubectl get httproute -n observability grafana

# Service accessible via port-forward
kubectl port-forward -n observability svc/grafana 3000:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5
curl -s http://localhost:3000/login | grep -q "Grafana" && echo "✓ Grafana responding"
kill $PF_PID

# MANUAL VALIDATION (operator):
# 1. Open https://grafana.quido.me (or kubectl port-forward)
# 2. Log in with admin/<vault-password>
# 3. Navigate to Configuration → Data Sources → Prometheus
#    - Click "Save & Test"
#    - Verify "Data source is working"
# 4. Navigate to Dashboards → Browse
#    - Verify 3 dashboards exist:
#      * Kubernetes Cluster Monitoring (ID 315)
#      * Node Exporter Full (ID 1860)
#      * Kubernetes Pods (ID 6417)
# 5. Open any dashboard, verify data is displayed
```

---

### Phase 4: End-to-End Validation

**Goal**: Verify the complete observability stack is functional

**Scope**: Run comprehensive validation checks across all components

#### Changes

No configuration changes—validation only.

#### Validations

```bash
# 1. All pods healthy
kubectl get pods -n observability
# Expected:
# - prometheus-server-xxx                      1/1 Running
# - prometheus-node-exporter-xxx (per node)    1/1 Running
# - kube-state-metrics-xxx                     1/1 Running
# - grafana-xxx                                1/1 Running

# 2. All PVCs bound
kubectl get pvc -n observability
# Expected:
# - prometheus-server   Bound   15Gi   democratic-csi-nfs
# - grafana             Bound   5Gi    democratic-csi-nfs

# 3. Prometheus scraping targets
kubectl port-forward -n observability svc/prometheus-server 9090:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5
TARGETS=$(curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.health == "up") | .labels.job' | wc -l)
echo "Active targets: $TARGETS (expected >= 5)"
kill $PF_PID

# 4. Historical data (wait 10 minutes after deployment)
kubectl port-forward -n observability svc/prometheus-server 9090:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5
DATAPOINTS=$(curl -s 'http://localhost:9090/api/v1/query_range?query=up&start='$(date -d '10 minutes ago' +%s)'&end='$(date +%s)'&step=60' | jq -r '.data.result[0].values | length')
echo "Historical datapoints: $DATAPOINTS (expected ~10)"
kill $PF_PID

# 5. Failure scenario: Prometheus restart with data persistence
kubectl delete pod -n observability -l app.kubernetes.io/name=prometheus
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n observability --timeout=120s

# Re-query historical data (should still exist)
kubectl port-forward -n observability svc/prometheus-server 9090:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5
curl -s 'http://localhost:9090/api/v1/query?query=up&time='$(date -d '10 minutes ago' +%s) | jq -r '.data.result | length'
# Should return > 0 (data survived restart)
kill $PF_PID

# 6. MANUAL: Verify Grafana dashboards show data
# - Open each dashboard (Cluster, Nodes, Pods)
# - Verify panels display metrics
# - Verify time range selector works
# - Test dashboard search and filtering

# 7. Document observed metrics
kubectl port-forward -n observability svc/prometheus-server 9090:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5
echo "=== Observability Stack Metrics ==="
echo "Active time series:"
curl -s 'http://localhost:9090/api/v1/query?query=count({__name__=~".+"})' | jq -r '.data.result[0].value[1]'
echo "Active scrape targets:"
curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets | length'
echo "Storage retention: 30 days"
echo "Scrape interval: 60 seconds"
kill $PF_PID
```

---

### Phase 5: Create Validation Script (Optional)

**Goal**: Automate validation checks for future use

**Scope**: Create reusable validation script

#### Changes

**Create `infrastructure/observability/validate.sh`:**
```bash
#!/bin/bash
set -e

echo "=== Observability Stack Validation ==="
echo ""

# Pre-flight checks
echo "[1/5] Checking prerequisites..."
kubectl get storageclass democratic-csi-nfs > /dev/null 2>&1 && echo "  ✓ Storage class exists" || (echo "  ✗ Storage class missing" && exit 1)
kubectl get gateway -n networking gateway-internal > /dev/null 2>&1 && echo "  ✓ Gateway exists" || echo "  ⚠ Gateway missing (HTTPRoute will be orphaned)"

# Health checks
echo ""
echo "[2/5] Checking pod health..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-node-exporter -n observability --timeout=30s > /dev/null 2>&1 && echo "  ✓ node-exporter healthy" || (echo "  ✗ node-exporter unhealthy" && exit 1)
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kube-state-metrics -n observability --timeout=30s > /dev/null 2>&1 && echo "  ✓ kube-state-metrics healthy" || (echo "  ✗ kube-state-metrics unhealthy" && exit 1)
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n observability --timeout=30s > /dev/null 2>&1 && echo "  ✓ prometheus healthy" || (echo "  ✗ prometheus unhealthy" && exit 1)
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n observability --timeout=30s > /dev/null 2>&1 && echo "  ✓ grafana healthy" || (echo "  ✗ grafana unhealthy" && exit 1)

# PVC checks
echo ""
echo "[3/5] Checking persistent volumes..."
PROM_PVC=$(kubectl get pvc -n observability prometheus-server -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
[ "$PROM_PVC" = "Bound" ] && echo "  ✓ Prometheus PVC bound" || (echo "  ✗ Prometheus PVC not bound" && exit 1)
GRAFANA_PVC=$(kubectl get pvc -n observability grafana -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
[ "$GRAFANA_PVC" = "Bound" ] && echo "  ✓ Grafana PVC bound" || (echo "  ✗ Grafana PVC not bound" && exit 1)

# Prometheus scraping
echo ""
echo "[4/5] Checking Prometheus scrape targets..."
kubectl port-forward -n observability svc/prometheus-server 9090:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5
TARGETS=$(curl -s http://localhost:9090/api/v1/targets 2>/dev/null | jq -r '.data.activeTargets[] | select(.health == "up") | .labels.job' | wc -l)
kill $PF_PID 2>/dev/null
if [ "$TARGETS" -ge 5 ]; then
  echo "  ✓ Prometheus scraping $TARGETS targets (expected >= 5)"
else
  echo "  ✗ Only $TARGETS targets up (expected >= 5)"
  exit 1
fi

# Metrics data
echo ""
echo "[5/5] Checking metrics data availability..."
kubectl port-forward -n observability svc/prometheus-server 9090:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5
NODE_METRICS=$(curl -s 'http://localhost:9090/api/v1/query?query=node_cpu_seconds_total' 2>/dev/null | jq -r '.data.result | length')
POD_METRICS=$(curl -s 'http://localhost:9090/api/v1/query?query=kube_pod_info' 2>/dev/null | jq -r '.data.result | length')
kill $PF_PID 2>/dev/null
[ "$NODE_METRICS" -gt 0 ] && echo "  ✓ Node metrics available ($NODE_METRICS series)" || (echo "  ✗ No node metrics" && exit 1)
[ "$POD_METRICS" -gt 0 ] && echo "  ✓ Pod metrics available ($POD_METRICS series)" || (echo "  ✗ No pod metrics" && exit 1)

echo ""
echo "=== Automated Validation Complete ==="
echo ""
echo "Manual checks (operator only):"
echo "  1. Verify Vault secret: vault kv get kv/observability/grafana"
echo "  2. Access Grafana: https://grafana.quido.me (or kubectl port-forward)"
echo "  3. Log in with admin/<vault-password>"
echo "  4. Verify dashboards loaded (3 expected)"
echo "  5. Verify data source working (Prometheus)"
echo ""
```

**Deployment:**
```bash
chmod +x infrastructure/observability/validate.sh
git add infrastructure/observability/validate.sh
git commit -m "feat(observability): add validation script"
git push
```

**Note**: This phase can be deferred or skipped if time-constrained. Not critical for deployment success.

---

## Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| Modular deployment (separate charts) | Better resource control (~100MB savings), independent component versioning, clearer separation of concerns vs kube-prometheus-stack |
| 15GB Prometheus PVC | 30-day retention with ~50% headroom for small cluster (10GB estimated usage) |
| democratic-csi NFS storage | Existing proven storage class, simplifies PVC provisioning |
| 60-second scrape interval | Balances resolution vs resource usage for non-critical home lab workload |
| Node exporter as DaemonSet | Standard pattern ensures metrics from all nodes |
| Single kube-state-metrics replica | Home lab doesn't need HA, reduces resource footprint |
| Grafana data source via Helm values | Declarative, version-controlled, avoids manual UI configuration |
| Community dashboard auto-import | Ensures reproducibility, dashboards tracked in Git |
| HTTPRoute to gateway-internal | Enables external access now, easy one-line migration to gateway-external later |
| ClusterIP for Prometheus | Security: no external access needed, Grafana queries internally |
| Vault + Vals for Grafana password | Consistent with platform secret management pattern |
| Manual ArgoCD sync policy | Consistent with all infrastructure components, explicit operator control |

## Non-Goals

**Explicitly NOT included in this story:**

- ❌ AlertManager deployment (future enhancement)
- ❌ Application instrumentation (future enhancement after infrastructure metrics proven)
- ❌ External gateway creation (separate networking story)
- ❌ Log aggregation with Loki (separate observability story)
- ❌ Distributed tracing with Tempo (separate observability story)
- ❌ Multi-environment configuration (single home lab environment only)
- ❌ Prometheus HA with multiple replicas (unnecessary for home lab scale)
- ❌ Long-term metrics storage with Thanos (30-day retention sufficient)
- ❌ Custom application ServiceMonitors (start with infrastructure metrics only)

## Validation Plan

### Existing Validations (Must Pass)

**None exist currently.** This deployment establishes the first formal validation approach for the platform.

### New Validations

**Phase 1 validations:**
- node-exporter DaemonSet running on all nodes
- kube-state-metrics pod running and healthy
- Services exist and have endpoints

**Phase 2 validations:**
- Prometheus pod running and healthy
- Prometheus PVC bound to 15GB volume
- Prometheus scraping at least 5 target types
- Metrics data available (node and pod metrics)

**Phase 3 validations:**
- Grafana pod running and healthy
- Grafana PVC bound to 5GB volume
- HTTPRoute created and referencing Grafana service
- Grafana login page accessible
- Manual: Prometheus data source working
- Manual: 3 community dashboards imported

**Phase 4 validations:**
- End-to-end metrics flow (exporters → Prometheus → Grafana)
- Historical data persists across Prometheus restart
- Active time series and scrape target counts documented

**Phase 5 validations:**
- Validation script runs successfully
- All automated checks pass

## Implementation Checklist

- [ ] **Phase 1**: Deploy node-exporter and kube-state-metrics
  - [ ] Create helmfile.yaml and values.yaml for both components
  - [ ] Commit and push to Git
  - [ ] ArgoCD sync both applications
  - [ ] Run Phase 1 validations
- [ ] **Phase 2**: Deploy Prometheus
  - [ ] Create helmfile.yaml and values.yaml
  - [ ] Commit and push to Git
  - [ ] ArgoCD sync prometheus application
  - [ ] Run Phase 2 validations
- [ ] **Phase 3**: Deploy Grafana
  - [ ] Verify Vault secret exists: `vault kv get kv/observability/grafana`
  - [ ] Create helmfile.yaml.gotmpl, values.yaml, and HTTPRoute resource
  - [ ] Commit and push to Git
  - [ ] ArgoCD sync grafana application
  - [ ] Run Phase 3 validations (automated + manual)
- [ ] **Phase 4**: End-to-end validation
  - [ ] Run comprehensive validation checks
  - [ ] Verify historical data persistence
  - [ ] Document observed metrics (time series count, targets)
- [ ] **Phase 5** (Optional): Create validation script
  - [ ] Write validate.sh script
  - [ ] Test script execution
  - [ ] Commit to Git
- [ ] **Post-deployment**:
  - [ ] Verify all existing validations pass (N/A - none exist)
  - [ ] Update GITOPS.md if new patterns established (N/A - follows existing patterns)

## Migration Strategy

**No migration required.** This is a net-new deployment.

**Relationship to existing components:**
- **metrics-server**: Remains unchanged, continues providing metrics for HPA
- **Prometheus complements metrics-server**: metrics-server provides real-time metrics API, Prometheus provides historical storage and broader coverage
- **No conflicts**: Both can coexist in the observability namespace

**Future migration (when gateway-external exists):**
1. Update `infrastructure/observability/grafana/resources/templates/http-route.yaml`
2. Change line: `name: gateway-internal` → `name: gateway-external`
3. Commit and sync: `argocd app sync observability-grafana`
4. Verify Grafana accessible via new gateway

## Security Considerations

**RBAC:**
- Prometheus ServiceAccount: ClusterRole with read-only access to pods, services, endpoints, nodes, namespaces, ingresses (all namespaces) - auto-created by Helm chart
- kube-state-metrics ServiceAccount: ClusterRole with read-only access to all Kubernetes objects - auto-created by Helm chart
- node-exporter: Runs in hostNetwork and hostPID mode (required for node metrics), no additional RBAC needed
- Grafana: No special RBAC (queries Prometheus via ClusterIP service)

**Network Security:**
- Prometheus: ClusterIP only, no external access (internal scraping and Grafana queries only)
- Grafana: External access via HTTPRoute + Gateway, TLS handled by gateway certificate
- node-exporter: ClusterIP service, accessible within cluster for Prometheus scraping
- kube-state-metrics: ClusterIP service, accessible within cluster for Prometheus scraping

**Secrets Management:**
- Grafana admin password: Stored in Vault at `kv/observability/grafana#admin-password`
- Injected at deploy-time via Vals in `helmfile.yaml.gotmpl`
- No hardcoded secrets in values files
- Failure mode: If Vault unavailable, ArgoCD sync fails (fail-closed)

**Pod Security:**
- node-exporter requires `hostNetwork: true` and `hostPID: true` (necessary for node metrics collection)
- All other pods use standard security context (no privileged containers)
- Resource limits enforced to prevent resource exhaustion attacks

**Data Privacy:**
- Metrics may contain sensitive information (pod names, namespace names, label values)
- 30-day retention policy limits data exposure window
- No external export of metrics (Prometheus not exposed externally)
- Access to Grafana requires authentication (admin password from Vault)

## Disaster Recovery

**Recovery procedure:**

All configuration is in Git. To recover from complete cluster loss:

1. **Restore Vault secret** (from backup):
   ```bash
   vault kv put kv/observability/grafana admin-password="<password>"
   ```

2. **ArgoCD will auto-deploy** (ApplicationSet detects `infrastructure/observability/*`):
   ```bash
   argocd app list | grep observability
   # Sync if needed:
   argocd app sync observability-node-exporter
   argocd app sync observability-kube-state-metrics
   argocd app sync observability-prometheus
   argocd app sync observability-grafana
   ```

3. **Historical metrics are lost** (PVs deleted):
   - Prometheus starts collecting new metrics immediately
   - Grafana dashboards repopulate as data accumulates
   - Historical data before disaster is unrecoverable

**Backup considerations:**

- **Configuration**: All in Git (fully recoverable)
- **Grafana admin password**: In Vault (ensure Vault is backed up)
- **Grafana dashboards**: Auto-provisioned from values.yaml (recoverable)
- **Prometheus metrics**: Stored on PVC (lost if PVC deleted)
  - **Recommendation**: If historical metrics are critical, implement Prometheus backup (e.g., snapshot PVC, or deploy Thanos for long-term storage)
  - **For home lab**: Acceptable to lose historical data in disaster scenario

**Recovery time:**
- Configuration recovery: ~5 minutes (ArgoCD sync)
- Metrics collection resumption: Immediate (Prometheus starts scraping)
- Dashboard availability: ~2 minutes (Grafana pod startup + dashboard provisioning)
- Full operational state: ~10 minutes (all pods running, metrics flowing)

**Testing recovery:**
1. Delete all observability deployments: `kubectl delete namespace observability`
2. Wait for ArgoCD to detect drift (OutOfSync)
3. Manually sync applications in order (exporters → Prometheus → Grafana)
4. Verify dashboards show data (new metrics only, historical lost)

---

## Summary

This story deploys a modular Prometheus and Grafana observability stack across 4-5 phases:

1. **Metrics exporters** (node-exporter, kube-state-metrics)
2. **Prometheus** (metrics collection and storage)
3. **Grafana** (visualization with dashboards and HTTPRoute)
4. **End-to-end validation** (comprehensive checks)
5. **Validation script** (optional automation)

**Key outcomes:**
- Centralized cluster metrics with 30-day retention
- Pre-configured dashboards for cluster, node, and pod monitoring
- Fast detection of failures and resource issues
- Foundation for future application instrumentation and alerting
- All configuration in Git, managed by ArgoCD

**Estimated deployment time**: 2.5-3 hours (excluding optional Phase 5)

**Resource footprint**: ~1-1.2GB memory, 20GB storage (15GB Prometheus + 5GB Grafana)
