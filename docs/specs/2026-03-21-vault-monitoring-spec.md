# Story: Vault Observability & Monitoring

**Design Spec**: [../stories/2026-03-21-vault-observability-story.md](../stories/2026-03-21-vault-observability-story.md)
**Status**: Pending
**Created**: 2026-03-21

## Objective

Deploy comprehensive observability for Vault (seal status, resources, downstream impact) with Prometheus metrics, Grafana dashboards, and Alertmanager alerts to proactively detect Vault failures before they cascade across the platform.

## Functional Requirements Summary

**Context**: Vault is critical infrastructure providing secret management for deploy-time (ArgoCD + vals) and runtime (External Secrets Operator) injection. Vault failures cascade across the platform, causing deploy-time failures (ArgoCD syncs) and runtime failures (stale secrets). Operators have been repeatedly surprised by Vault issues discovered only after downstream failures.

**Two-tier monitoring approach**:
1. **Tier 1 - Direct Vault Health**: Monitor seal status, resource usage, availability
2. **Tier 2 - Downstream Impact**: Monitor ExternalSecrets sync failures, token expiration

**Deployment stories** (from functional spec):
1. Vault health metrics collection (Prometheus scraping)
2. Vault seal status alerting (critical alerts)
3. Vault resource monitoring (memory - CPU removed, covered by generic alert)
4. ExternalSecrets sync failure detection (blast radius visibility)
5. Vault token expiration warnings (proactive rotation)
6. Grafana dashboard - Vault Health Overview
7. Grafana dashboard - Vault Blast Radius

**Key decisions**:
- **VaultCPUThrottled removed**: Generic `CPUThrottlingHigh` alert from kube-prometheus-stack already covers all containers including Vault
- **DR testing removed**: Requires backup solution not in scope; gap documented
- **Time-based token expiration**: Simpler than custom exporter, sufficient for 1-year TTL

## Current State

**Existing infrastructure**:
- ✅ Vault deployed in `security` namespace (standalone mode, file storage, no telemetry)
- ✅ kube-prometheus-stack deployed in `observability` namespace
- ✅ Storage class `truenas-iscsi` with Retain policy
- ✅ ArgoCD ApplicationSet auto-discovers `infrastructure/*/*`
- ❌ No Vault metrics collection
- ❌ No Vault-specific alerts
- ❌ No Vault dashboards
- ❌ No automated backups (DR gap - out of scope)

**Validation patterns**:
- proxmox-exporter has `validate.sh` script (template for this work)
- kube-prometheus-stack provides generic K8s health alerts

## Design

### Phase 0: Prerequisites & Validation Setup

**Goal**: Verify environment is ready and create validation tooling

**Scope**: Pre-flight checks, no deployments

#### Changes

**Verification steps**:
```bash
# 1. Check kube-prometheus-stack healthy
kubectl get prometheus -n observability
kubectl get pods -n observability -l app.kubernetes.io/name=kube-prometheus-stack

# 2. Check Vault deployed and unsealed
kubectl get pods -n security -l app.kubernetes.io/name=vault
kubectl exec -n security vault-0 -- vault status

# 3. Verify Grafana sidecar configuration
kubectl get deployment kube-prometheus-stack-grafana -n observability -o yaml | grep grafana-sc-dashboard
# Expected: sidecar container exists with dashboard label "grafana_dashboard"

# 4. Check kube-state-metrics for ExternalSecret CRD support
kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/query?query=kube_externalsecret_info' | jq '.data.result | length'
# Expected: > 0 (metrics available)

# 5. Document vals token creation date
# Check when vals-reader token was created (needed for expiration alert)
# Update this value in Phase 2 helmfile.yaml: valsTokenCreatedAt
```

**Create validation script**:
```bash
# Create infrastructure/observability/vault-monitoring/validate.sh
# Based on proxmox-exporter/validate.sh pattern
# 13 automated checks + 4 manual verification steps
# (Full script content in Phase 3 validation section)
```

#### Validations

**Prerequisites verified**:
- ✅ kube-prometheus-stack operational (Prometheus, Grafana, Alertmanager pods ready)
- ✅ Vault running and unsealed in security namespace
- ✅ Grafana sidecar enabled (if not: manual dashboard import required)
- ✅ kube-state-metrics exposes ExternalSecret metrics (if not: alert may not work)
- ✅ Vals token creation date documented

**Exit criteria**:
- All prerequisites confirmed healthy
- Validation script created (not executed yet)
- Token creation date documented for Phase 2

---

### Phase 1: Enable Vault Telemetry

**Goal**: Configure Vault to expose Prometheus metrics endpoint

**Scope**: Modify Vault configuration, restart pod, verify metrics

#### Changes

**File**: `infrastructure/security/vault/values.yaml`

**Before**:
```yaml
server:
  # Standalone mode for home lab
  standalone:
    enabled: true
    config: |
      disable_mlock = true

      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
      }

      storage "file" {
        path = "/vault/data"
      }

      ui = true
```

**After**:
```yaml
server:
  # Standalone mode for home lab
  standalone:
    enabled: true
    config: |
      disable_mlock = true

      # Enable telemetry for Prometheus monitoring
      telemetry {
        prometheus_retention_time = "30s"
        disable_hostname = false
        unauthenticated_metrics_access = true
      }

      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
      }

      storage "file" {
        path = "/vault/data"
      }

      ui = true
```

**What this does**:
- `unauthenticated_metrics_access = true`: Allows Prometheus to scrape without authentication (metrics contain no sensitive data)
- `prometheus_retention_time = "30s"`: Vault caches metrics for 30 seconds before recalculating
- `disable_hostname = false`: Includes hostname in metric labels

**Deployment steps**:
1. Commit Vault values.yaml change to Git
2. Push to remote repository
3. ArgoCD detects change and syncs Vault application
4. Vault StatefulSet updated, pod recreated
5. **Manual step**: Unseal Vault (pod restart always seals Vault)
   ```bash
   kubectl exec -n security vault-0 -- vault operator unseal <key1>
   kubectl exec -n security vault-0 -- vault operator unseal <key2>
   kubectl exec -n security vault-0 -- vault operator unseal <key3>
   ```
6. Verify metrics endpoint responding

#### Validations

```bash
# 1. Verify Vault pod restarted
kubectl get pods -n security -l app.kubernetes.io/name=vault
# Check age - should be recent

# 2. Check Vault unsealed
kubectl exec -n security vault-0 -- vault status
# Expected: Sealed: false

# 3. Test metrics endpoint
kubectl exec -n security vault-0 -- \
  wget -q -O- "http://localhost:8200/v1/sys/metrics?format=prometheus" | head -20
# Expected: Prometheus format metrics (# HELP, # TYPE, vault_* metrics)

# 4. Verify vault_core_unsealed metric present
kubectl exec -n security vault-0 -- \
  wget -q -O- "http://localhost:8200/v1/sys/metrics?format=prometheus" | grep vault_core_unsealed
# Expected: vault_core_unsealed 1
```

**Exit criteria**:
- ✅ Vault configuration updated in Git and synced
- ✅ Vault pod restarted with new configuration
- ✅ Vault unsealed (3 unseal keys applied)
- ✅ Metrics endpoint returns Prometheus format data
- ✅ `vault_core_unsealed` metric = 1

**Rollback**: Revert values.yaml commit, push to Git, ArgoCD syncs back to previous config, unseal Vault again

---

### Phase 2: Deploy Monitoring Chart

**Goal**: Deploy vault-monitoring Helm chart with ServiceMonitor and PrometheusRule

**Scope**: Create chart structure, templates, Helmfile, and deploy via ArgoCD

#### Changes

**New directory structure**:
```
infrastructure/observability/vault-monitoring/
├── helmfile.yaml                          # NEW - Deploy local chart
├── validate.sh                            # NEW - From Phase 0
└── helm-chart/                            # NEW - Local minimal Helm chart
    ├── Chart.yaml                         # NEW - Chart metadata
    ├── values.yaml                        # NEW - Default values
    ├── dashboards/                        # NEW - Dashboard JSON files
    │   ├── vault-health.json              # Placeholder (populated in Phase 3)
    │   └── vault-blast-radius.json        # Placeholder (populated in Phase 3)
    └── templates/
        ├── _helpers.tpl                   # NEW - Standard Helm helpers
        ├── servicemonitor.yaml            # NEW - Scrape Vault metrics
        ├── prometheusrule.yaml            # NEW - Alert rules
        ├── grafana-dashboard-health.yaml  # NEW - ConfigMap for health dashboard
        └── grafana-dashboard-blast-radius.yaml  # NEW - ConfigMap for blast radius dashboard
```

**File: `Chart.yaml`**:
```yaml
apiVersion: v2
name: vault-monitoring
description: Vault observability - metrics, alerts, and dashboards
type: application
version: 0.1.0
appVersion: "1.0"
```

**File: `values.yaml`**:
```yaml
# Vault target configuration
vault:
  namespace: security
  serviceName: vault
  servicePort: 8200
  metricsPath: /v1/sys/metrics
  metricsFormat: prometheus

# Scrape configuration
scrapeInterval: 15s
scrapeTimeout: 10s

# Alert configuration
alerts:
  enabled: true

  # Vault sealed alert
  sealed:
    enabled: true
    severity: critical

  # Resource alerts
  highMemory:
    enabled: true
    severity: warning
    threshold: 0.90  # 90% of limit

  # ExternalSecrets sync failures
  externalSecretFailure:
    enabled: true
    severity: warning
    waitDuration: 5m

  # Token expiration (time-based)
  tokenExpiration:
    enabled: true
    severity: warning
    # Document token creation date for manual calculation
    valsTokenCreatedAt: "2026-03-01"  # TODO: Update with actual token creation date from Phase 0
    warningDays: 7

# Dashboard configuration
dashboards:
  enabled: true
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "Infrastructure"
```

**File: `helmfile.yaml`**:
```yaml
repositories: []  # No external repos for local chart

releases:
  - name: vault-monitoring
    namespace: observability
    chart: ./helm-chart
    wait: true
    timeout: 300
    values:
      - vault:
          namespace: security
          serviceName: vault
          servicePort: 8200
          metricsPath: /v1/sys/metrics
          metricsFormat: prometheus

        scrapeInterval: 15s
        scrapeTimeout: 10s

        alerts:
          enabled: true
          sealed:
            enabled: true
            severity: critical
          highMemory:
            enabled: true
            severity: warning
            threshold: 0.90
          externalSecretFailure:
            enabled: true
            severity: warning
            waitDuration: 5m
          tokenExpiration:
            enabled: true
            severity: warning
            valsTokenCreatedAt: "2026-03-01"  # TODO: Update with actual vals token creation date
            warningDays: 7

        dashboards:
          enabled: true
          labels:
            grafana_dashboard: "1"
          annotations:
            grafana_folder: "Infrastructure"
```

**File: `templates/_helpers.tpl`**:
```yaml
{{/*
Expand the name of the chart.
*/}}
{{- define "vault-monitoring.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "vault-monitoring.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "vault-monitoring.labels" -}}
helm.sh/chart: {{ include "vault-monitoring.name" . }}
{{ include "vault-monitoring.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "vault-monitoring.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vault-monitoring.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

**File: `templates/servicemonitor.yaml`**:
```yaml
{{- if .Values.alerts.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "vault-monitoring.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "vault-monitoring.labels" . | nindent 4 }}
spec:
  namespaceSelector:
    matchNames:
      - {{ .Values.vault.namespace }}
  selector:
    matchLabels:
      app.kubernetes.io/name: vault
  endpoints:
    - port: http
      path: {{ .Values.vault.metricsPath }}
      params:
        format:
          - {{ .Values.vault.metricsFormat }}
      interval: {{ .Values.scrapeInterval }}
      scrapeTimeout: {{ .Values.scrapeTimeout }}
{{- end }}
```

**File: `templates/prometheusrule.yaml`**:
```yaml
{{- if .Values.alerts.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: {{ include "vault-monitoring.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "vault-monitoring.labels" . | nindent 4 }}
    prometheus: kube-prometheus-stack
    release: kube-prometheus-stack
spec:
  groups:
    - name: vault-health
      interval: 30s
      rules:
        {{- if .Values.alerts.sealed.enabled }}
        - alert: VaultSealed
          expr: vault_core_unsealed{namespace="{{ .Values.vault.namespace }}"} == 0
          for: 1m
          labels:
            severity: {{ .Values.alerts.sealed.severity }}
          annotations:
            summary: "Vault is sealed"
            description: "Vault in namespace {{ .Values.vault.namespace }} is sealed. Manual unseal required with 3 unseal keys."
            runbook_url: "https://github.com/quidome/gitops-lab/blob/main/infrastructure/security/vault/README.md#2-unseal-vault"
        {{- end }}

        {{- if .Values.alerts.highMemory.enabled }}
        - alert: VaultHighMemory
          expr: |
            (
              container_memory_working_set_bytes{namespace="{{ .Values.vault.namespace }}", pod=~"vault-.*"}
              /
              container_spec_memory_limit_bytes{namespace="{{ .Values.vault.namespace }}", pod=~"vault-.*"}
            ) > {{ .Values.alerts.highMemory.threshold }}
          for: 5m
          labels:
            severity: {{ .Values.alerts.highMemory.severity }}
          annotations:
            summary: "Vault memory usage above {{ mul .Values.alerts.highMemory.threshold 100 }}%"
            description: "Vault pod {{`{{ $labels.pod }}`}} memory usage is {{`{{ $value | humanizePercentage }}`}}. Consider increasing memory limits."
        {{- end }}

    - name: vault-downstream-impact
      interval: 30s
      rules:
        {{- if .Values.alerts.externalSecretFailure.enabled }}
        - alert: ExternalSecretSyncFailure
          expr: |
            kube_externalsecret_status_condition{condition="Ready", status="False"} == 1
          for: {{ .Values.alerts.externalSecretFailure.waitDuration }}
          labels:
            severity: {{ .Values.alerts.externalSecretFailure.severity }}
          annotations:
            summary: "ExternalSecret sync failure"
            description: "ExternalSecret {{`{{ $labels.namespace }}`}}/{{`{{ $labels.name }}`}} is failing to sync. Check Vault connectivity and authentication."
            runbook_url: "https://github.com/quidome/gitops-lab/blob/main/infrastructure/security/vault/README.md#when-the-approle-token-expires"
        {{- end }}

        {{- if .Values.alerts.tokenExpiration.enabled }}
        - alert: VaultTokenExpiringSoon
          # Time-based calculation: (current_time - token_creation_time) > (365 days - warning_days)
          # Note: This requires updating valsTokenCreatedAt when rotating the token
          expr: |
            (
              time() - {{ .Values.alerts.tokenExpiration.valsTokenCreatedAt | quote | toDate "2006-01-02" | unixEpoch }}
            ) > (
              (365 * 24 * 3600) - ({{ .Values.alerts.tokenExpiration.warningDays }} * 24 * 3600)
            )
          labels:
            severity: {{ .Values.alerts.tokenExpiration.severity }}
          annotations:
            summary: "Vault vals-reader token expiring soon"
            description: "Vals-reader token will expire in approximately {{ .Values.alerts.tokenExpiration.warningDays }} days. Rotation required to prevent ArgoCD sync failures."
            runbook_url: "https://github.com/quidome/gitops-lab/blob/main/infrastructure/security/vault/README.md#when-the-vals-reader-token-expires"
        {{- end }}
{{- end }}
```

**File: `templates/grafana-dashboard-health.yaml`**:
```yaml
{{- if .Values.dashboards.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "vault-monitoring.fullname" . }}-health
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "vault-monitoring.labels" . | nindent 4 }}
    {{- with .Values.dashboards.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .Values.dashboards.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
data:
  vault-health.json: |-
    {{- .Files.Get "dashboards/vault-health.json" | nindent 4 }}
{{- end }}
```

**File: `templates/grafana-dashboard-blast-radius.yaml`**:
```yaml
{{- if .Values.dashboards.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "vault-monitoring.fullname" . }}-blast-radius
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "vault-monitoring.labels" . | nindent 4 }}
    {{- with .Values.dashboards.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .Values.dashboards.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
data:
  vault-blast-radius.json: |-
    {{- .Files.Get "dashboards/vault-blast-radius.json" | nindent 4 }}
{{- end }}
```

**File: `dashboards/vault-health.json`** (placeholder):
```json
{
  "title": "Vault - Health Overview",
  "panels": []
}
```

**File: `dashboards/vault-blast-radius.json`** (placeholder):
```json
{
  "title": "Vault - Downstream Impact",
  "panels": []
}
```

**Implementation order**:
1. Create directory structure
2. Write all files listed above
3. **CRITICAL**: Update `valsTokenCreatedAt` in helmfile.yaml with actual token creation date from Phase 0
4. Commit to Git: `git add infrastructure/observability/vault-monitoring/`
5. Commit message: `feat(observability): add vault monitoring with metrics, alerts, and dashboards`
6. Push to remote
7. ArgoCD discovers new `infrastructure/observability/vault-monitoring/` via ApplicationSet pattern
8. ArgoCD syncs vault-monitoring application
9. ServiceMonitor, PrometheusRule, and ConfigMaps created in observability namespace

#### Validations

Run validation script (first 9 checks):
```bash
cd infrastructure/observability/vault-monitoring
./validate.sh
```

**Automated checks**:
1. ✅ Prerequisites exist (observability and security namespaces)
2. ✅ ArgoCD application vault-monitoring Synced and Healthy
3. ✅ Vault running and unsealed
4. ✅ Vault telemetry configuration present
5. ✅ ServiceMonitor created
6. ✅ ServiceMonitor targets security namespace
7. ✅ Vault metrics endpoint responding
8. ✅ Prometheus target UP (wait ~30 seconds for discovery)
9. ✅ Vault metrics queryable in Prometheus (`vault_core_unsealed` present)
10. ✅ PrometheusRule created with 4 alerts
11. ✅ Alert rules loaded in Prometheus (vault-health and vault-downstream-impact groups)
12. ✅ Dashboard ConfigMaps created (placeholder content)
13. ✅ Grafana sidecar enabled (or warn if not)
14. ✅ kube-state-metrics exposes ExternalSecret metrics
15. ✅ Token creation date configured (not default 2026-03-01)

**Manual checks**:
```bash
# Verify alerts visible in Prometheus UI
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# Navigate to http://localhost:9090/alerts
# Check for: VaultSealed, VaultHighMemory, ExternalSecretSyncFailure, VaultTokenExpiringSoon

# Verify metrics flowing
# Navigate to http://localhost:9090/graph
# Query: vault_core_unsealed
# Expected: Result shows value 1
```

**Exit criteria**:
- ✅ All files created and committed to Git
- ✅ ArgoCD application Synced and Healthy
- ✅ ServiceMonitor scraping Vault (Prometheus target UP)
- ✅ PrometheusRule loaded (4 alerts visible in Prometheus UI)
- ✅ Vault metrics queryable (`vault_core_unsealed = 1`)
- ✅ Dashboard ConfigMaps created (placeholder content)
- ✅ Token creation date updated from default

**Rollback**: Delete `infrastructure/observability/vault-monitoring/` directory, commit and push to Git

---

### Phase 3: Create Grafana Dashboards

**Goal**: Build and deploy functional Vault dashboards

**Scope**: Create dashboard JSON, update ConfigMaps, verify import in Grafana

#### Changes

**Update files**:
```
infrastructure/observability/vault-monitoring/helm-chart/dashboards/
├── vault-health.json          # UPDATE with actual dashboard
└── vault-blast-radius.json    # UPDATE with actual dashboard
```

**Dashboard creation process**:

1. **Access Grafana UI**:
   ```bash
   kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
   # Navigate to http://localhost:3000
   # Login: admin / prom-operator (or check kube-prometheus-stack secret)
   ```

2. **Create Vault Health Overview dashboard**:
   - New Dashboard → Add visualization
   - **Panel 1: Seal Status** (Stat panel)
     - Query: `vault_core_unsealed{namespace="security"}`
     - Value mappings: 0 = "SEALED" (red), 1 = "UNSEALED" (green)
   - **Panel 2: Memory Usage** (Gauge)
     - Query: `container_memory_working_set_bytes{namespace="security",pod=~"vault-.*"} / container_spec_memory_limit_bytes{namespace="security",pod=~"vault-.*"}`
   - **Panel 3: Memory Trend** (Graph)
     - Same query as Panel 2, time series
   - **Panel 4: Request Rate** (Graph)
     - Query: `rate(vault_core_handle_request_count{namespace="security"}[5m])`
   - **Panel 5: Response Latency p50/p95/p99** (Graph)
     - Query: `histogram_quantile(0.50, rate(vault_core_handle_request_duration_bucket{namespace="security"}[5m]))`
     - Repeat for 0.95 and 0.99
   - **Panel 6: Active Tokens** (Stat)
     - Query: `vault_core_check_token_count{namespace="security"}`
   - **Panel 7: Uptime** (Stat)
     - Query: `time() - process_start_time_seconds{namespace="security",pod=~"vault-.*"}`
   - Save dashboard, set folder to "Infrastructure"

3. **Export dashboard JSON**:
   - Dashboard settings → JSON Model → Copy JSON
   - Paste into `dashboards/vault-health.json`
   - Remove `id` field (should be null for imports)
   - Set `uid` to a stable value: `"vault-health-overview"`

4. **Create Vault Blast Radius dashboard**:
   - New Dashboard → Add visualization
   - **Panel 1: Failing ExternalSecrets** (Stat)
     - Query: `count(kube_externalsecret_status_condition{condition="Ready",status="False"} == 1) or vector(0)`
   - **Panel 2: ExternalSecrets by Namespace** (Bar gauge)
     - Query: `count by (namespace) (kube_externalsecret_status_condition{condition="Ready",status="False"} == 1)`
   - **Panel 3: ExternalSecret Details** (Table)
     - Query: `kube_externalsecret_status_condition{condition="Ready",status="False"} == 1`
     - Show: namespace, name, condition
   - **Panel 4: Sync Failure Rate** (Graph)
     - Query: `rate(kube_externalsecret_sync_calls_error[5m])`
   - **Panel 5: Vault Seal Events** (Graph with annotations)
     - Query: `vault_core_unsealed{namespace="security"}`
     - Add annotations for seal/unseal events
   - Save dashboard, set folder to "Infrastructure"

5. **Export blast radius dashboard JSON**:
   - Dashboard settings → JSON Model → Copy JSON
   - Paste into `dashboards/vault-blast-radius.json`
   - Remove `id` field
   - Set `uid` to: `"vault-blast-radius"`

6. **Commit and deploy**:
   ```bash
   git add infrastructure/observability/vault-monitoring/helm-chart/dashboards/
   git commit -m "feat(vault-monitoring): add Grafana dashboards for health and blast radius"
   git push
   # ArgoCD syncs, ConfigMaps updated with dashboard JSON
   # Grafana sidecar auto-imports (if enabled)
   ```

#### Validations

```bash
# 1. Verify ConfigMaps updated
kubectl get configmap -n observability -l grafana_dashboard=1 | grep vault-monitoring
# Expected: vault-monitoring-health and vault-monitoring-blast-radius

# 2. Check ConfigMap content
kubectl get configmap vault-monitoring-health -n observability -o jsonpath='{.data.vault-health\.json}' | jq '.title'
# Expected: "Vault - Health Overview"

# 3. Access Grafana and verify dashboards imported
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# Navigate to http://localhost:3000
# Go to Dashboards → Browse → Infrastructure folder
# Verify dashboards present:
#   - "Vault - Health Overview"
#   - "Vault - Downstream Impact"

# 4. Open each dashboard and verify panels populate
# Vault - Health Overview:
#   - Seal Status shows "UNSEALED" (green)
#   - Memory Usage shows percentage
#   - Request Rate shows data
#   - Active Tokens shows count
# Vault - Downstream Impact:
#   - Failing ExternalSecrets shows 0 (if all healthy)
#   - ExternalSecret Details table shows data
```

**Exit criteria**:
- ✅ Dashboard JSON files created and committed
- ✅ ConfigMaps updated with dashboard JSON (not placeholders)
- ✅ Dashboards visible in Grafana UI under Infrastructure folder
- ✅ Dashboard panels populate with Vault metrics (not "No data")
- ✅ Seal status panel shows "UNSEALED" (green)
- ✅ Memory, request rate, and other panels show current data

**Rollback**: Revert dashboard JSON files to placeholder content, commit and push

---

### Phase 4: Alert Testing & Tuning

**Goal**: Verify alerts fire correctly and tune thresholds if needed

**Scope**: Test alert scenarios, verify Pushover delivery, adjust thresholds

#### Changes

**No code changes** - Testing and validation only. Threshold tuning if needed.

**Test scenarios**:

**Test 1: VaultSealed alert**:
```bash
# 1. Seal Vault
kubectl exec -n security vault-0 -- vault operator seal

# 2. Wait 1 minute (alert has "for: 1m" condition)

# 3. Verify alert fires in Prometheus
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# Navigate to http://localhost:9090/alerts
# Check: VaultSealed alert should be FIRING

# 4. Verify alert in Alertmanager
kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093
# Navigate to http://localhost:9093
# Check: VaultSealed alert visible

# 5. Check Pushover notification received (manual verification)
# Expected: Mobile notification with message "Vault is sealed in namespace security"

# 6. Unseal Vault
kubectl exec -n security vault-0 -- vault operator unseal <key1>
kubectl exec -n security vault-0 -- vault operator unseal <key2>
kubectl exec -n security vault-0 -- vault operator unseal <key3>

# 7. Verify alert resolves
# Check Prometheus UI - VaultSealed should change to RESOLVED
# Check Pushover - should receive resolution notification (if configured)
```

**Test 2: VaultHighMemory alert** (optional - may not trigger easily):
```bash
# Check current memory usage
kubectl top pod vault-0 -n security

# If memory usage approaches 90%, alert should fire after 5 minutes
# Monitor with: kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
#   wget -q -O- 'http://localhost:9090/api/v1/query?query=container_memory_working_set_bytes{namespace="security",pod=~"vault-.*"}/container_spec_memory_limit_bytes{namespace="security",pod=~"vault-.*"}'

# If alert fires inappropriately, consider tuning threshold from 0.90 to 0.95 in values.yaml
```

**Test 3: ExternalSecretSyncFailure alert**:
```bash
# 1. Create broken ExternalSecret
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: test-broken
  namespace: default
spec:
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: test-secret
  data:
    - secretKey: test
      remoteRef:
        key: kv/nonexistent/path
        property: nonexistent
EOF

# 2. Wait 5 minutes (alert waitDuration)

# 3. Verify alert fires
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# Navigate to http://localhost:9090/alerts
# Check: ExternalSecretSyncFailure alert FIRING

# 4. Check Pushover notification

# 5. Clean up
kubectl delete externalsecret test-broken -n default

# 6. Verify alert resolves
```

**Test 4: VaultTokenExpiringSoon alert** (verify configuration):
```bash
# 1. Check configured token creation date
kubectl get prometheusrule vault-monitoring -n observability -o yaml | grep valsTokenCreatedAt

# 2. Verify token creation date is accurate
# Compare with actual token creation from Phase 0 documentation

# 3. Calculate days until expiration
# If token created on 2026-03-01, it expires on 2027-03-01 (365 days later)
# Alert should fire 7 days before (2027-02-22)

# 4. To test alert logic (optional):
# Temporarily set valsTokenCreatedAt to 358 days ago
# Edit helmfile.yaml: valsTokenCreatedAt: "2025-03-29"
# Commit and push
# Alert should fire immediately
# Revert after test
```

**Threshold tuning** (if needed):

If alerts fire inappropriately:
```yaml
# Edit helmfile.yaml

# Option 1: Increase memory threshold (if too many false positives)
alerts:
  highMemory:
    threshold: 0.95  # Change from 0.90 to 0.95

# Option 2: Increase ExternalSecret wait duration (if transient failures common)
alerts:
  externalSecretFailure:
    waitDuration: 10m  # Change from 5m to 10m

# Commit, push, ArgoCD syncs updated thresholds
```

#### Validations

```bash
# Run full validation script
cd infrastructure/observability/vault-monitoring
./validate.sh

# All 13 automated checks should pass

# Manual verification checklist:
# ✅ VaultSealed alert fires when Vault sealed
# ✅ VaultSealed alert resolves when Vault unsealed
# ✅ Pushover notifications received for VaultSealed
# ✅ ExternalSecretSyncFailure alert fires for broken ExternalSecret
# ✅ ExternalSecretSyncFailure alert resolves when ExternalSecret fixed
# ✅ Token expiration date verified accurate
# ✅ All alerts visible in Alertmanager UI
# ✅ Alert thresholds appropriate (tune if needed)
```

**Exit criteria**:
- ✅ VaultSealed alert fires and resolves correctly
- ✅ Pushover notifications delivered (verified manually)
- ✅ ExternalSecretSyncFailure alert tested and working
- ✅ Token expiration configuration verified
- ✅ Alert thresholds tuned if needed (or confirmed appropriate)
- ✅ All alerts resolve cleanly after fixing conditions
- ✅ Full validation script passes

**Rollback**: No changes committed; threshold tuning can be reverted if needed

---

## Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| **Local Helm chart vs external chart** | Full control over templates, no external dependencies, simple deployment (4 templates only), consistent with proxmox-exporter pattern |
| **Unauthenticated Vault metrics** | Metrics contain no sensitive data, simplifies ServiceMonitor configuration, standard Prometheus practice for metrics endpoints |
| **Cross-namespace scraping** | Monitoring in `observability` namespace, target in `security` namespace - proper separation of concerns, ServiceMonitor supports this natively |
| **kube-state-metrics for ExternalSecrets** | Fallback if external-secrets-operator metrics unavailable, always works, simpler dependency, already deployed |
| **Time-based token expiration** | Simpler than custom exporter, sufficient for 1-year TTL, documented in values.yaml, acceptable manual tracking for infrequent rotation |
| **Two separate dashboards** | Clear separation of operational health vs impact analysis, easier navigation, different audiences (ops vs troubleshooting) |
| **No Helmfile environments** | Single production environment, no dev/staging differences needed for infrastructure monitoring |
| **Remove VaultCPUThrottled** | Generic `CPUThrottlingHigh` alert from kube-prometheus-stack already monitors ALL containers including Vault, eliminates redundancy |
| **Alert grouping in Alertmanager** | Reduce notification spam when multiple alerts fire (VaultSealed + ExternalSecret failures), handled in existing kube-prometheus-stack config |
| **Retain storage class reclaim policy** | PV survives PVC deletion, critical for disaster recovery (though automated backups not in scope) |

---

## Non-Goals

**Explicitly NOT included in this work:**

- ❌ **Vault backup automation** - Manual procedures documented, automation is separate work
- ❌ **Disaster recovery testing** - Requires backup solution, out of scope
- ❌ **Generic platform health monitoring** - kube-prometheus-stack provides generic alerts, platform-wide improvements are separate work
- ❌ **Custom token TTL exporter** - Using time-based alerting instead (simpler, sufficient)
- ❌ **ArgoCD vals failure detection** - ArgoCD doesn't expose vals-specific metrics, limitation accepted
- ❌ **VaultCPUThrottled alert** - Redundant with generic `CPUThrottlingHigh` alert
- ❌ **Vault certificate expiration monitoring** - Vault uses HTTP (no TLS), cert-manager handles cert expiration if TLS added later
- ❌ **Grafana sidecar enablement** - Assumes already enabled, manual dashboard import if not
- ❌ **kube-state-metrics ExternalSecret CRD enablement** - Assumes already enabled, validation checks this

---

## Validation Plan

### Existing Validations (Must Pass)

**kube-prometheus-stack health**:
- ✅ Prometheus pods ready and operational
- ✅ Grafana pods ready and operational
- ✅ Alertmanager pods ready and operational
- ✅ Generic Kubernetes alerts functioning (`KubePodNotReady`, `CPUThrottlingHigh`, etc.)

**Vault health**:
- ✅ Vault pod ready
- ✅ Vault unsealed (manual check)
- ✅ Vault service accessible

### New Validations

**Validation script**: `infrastructure/observability/vault-monitoring/validate.sh`

**Automated checks (13 total)**:
1. ✅ Prerequisites exist (observability and security namespaces)
2. ✅ ArgoCD application vault-monitoring Synced and Healthy
3. ✅ Vault running and unsealed
4. ✅ Vault telemetry configuration present in StatefulSet
5. ✅ ServiceMonitor exists
6. ✅ ServiceMonitor targets security namespace (cross-namespace selector)
7. ✅ Vault metrics endpoint responding (direct pod check)
8. ✅ Prometheus target UP (ServiceMonitor discovered)
9. ✅ Vault metrics queryable in Prometheus (`vault_core_unsealed` present)
10. ✅ PrometheusRule exists with 4 alerts
11. ✅ Alert rules loaded in Prometheus (vault-health and vault-downstream-impact groups)
12. ✅ Dashboard ConfigMaps exist with `grafana_dashboard=1` label
13. ✅ Grafana sidecar enabled (or warning if not)
14. ✅ kube-state-metrics exposes ExternalSecret metrics (or warning if not)
15. ✅ Token creation date configured (not default value)

**Manual verification steps (4 total)**:
1. ⚠️ Verify alerts configured in Alertmanager UI (http://localhost:9093)
2. ⚠️ Verify dashboards imported in Grafana UI (http://localhost:3000)
3. ⚠️ Test VaultSealed alert firing (seal Vault, verify alert, unseal)
4. ⚠️ Verify Pushover notifications delivered

**Failure scenario tests (4 total)**:
1. ✅ Vault sealed → VaultSealed alert fires within 1 minute
2. ✅ Vault high memory → VaultHighMemory alert fires after 5 minutes (if testable)
3. ✅ ExternalSecret sync failure → ExternalSecretSyncFailure alert fires after 5 minutes
4. ✅ Token expiration approaching → VaultTokenExpiringSoon alert fires (configuration verified)

### Validation Gaps

**Known limitations**:
- ⚠️ **No automated backups** - Vault has manual DR procedures documented but not implemented
- ⚠️ **DR procedures untested** - Restore process never validated
- ⚠️ **Token expiration manual tracking** - Requires updating `valsTokenCreatedAt` in values when rotating token
- ⚠️ **Vals failure detection incomplete** - Cannot distinguish vals auth failures from other ArgoCD sync failures
- ⚠️ **Grafana sidecar dependency** - Dashboards won't auto-import if sidecar disabled (manual import required)
- ⚠️ **kube-state-metrics ExternalSecret dependency** - ExternalSecretSyncFailure alert won't work if CRD metrics not exposed

**Recommendations for future work**:
- Implement automated Vault backups (Velero or TrueNAS snapshot automation)
- Quarterly DR drills to validate restore procedures
- Consider custom token TTL exporter if token rotation becomes frequent
- Monitor for vals-specific errors in ArgoCD logs (custom exporter)

---

## Implementation Checklist

**Phase 0: Prerequisites & Validation Setup**
- [x] Verify kube-prometheus-stack healthy
- [x] Verify Vault deployed and unsealed
- [x] Check Grafana sidecar configuration
- [x] Check kube-state-metrics ExternalSecret CRD support
- [ ] Document vals token creation date
- [x] Create validate.sh script

**Phase 1: Enable Vault Telemetry**
- [x] Update infrastructure/security/vault/values.yaml (add telemetry block)
- [x] Commit and push to Git
- [x] ArgoCD syncs Vault application
- [x] Vault pod restarts
- [x] Unseal Vault (manual - 3 unseal keys)
- [x] Verify metrics endpoint responding
- [x] Verify vault_core_unsealed metric = 1

**Phase 2: Deploy Monitoring Chart**
- [x] Create directory structure: infrastructure/observability/vault-monitoring/
- [x] Write Chart.yaml
- [x] Write values.yaml
- [x] Write helmfile.yaml
- [ ] Update valsTokenCreatedAt with actual date
- [x] Write templates/_helpers.tpl
- [x] Write templates/servicemonitor.yaml
- [x] Write templates/prometheusrule.yaml
- [x] Write templates/grafana-dashboard-health.yaml
- [x] Write templates/grafana-dashboard-blast-radius.yaml
- [x] Create placeholder dashboard JSON files
- [x] Commit and push to Git
- [x] ArgoCD discovers and syncs vault-monitoring
- [x] Run validation script (checks 1-9)
- [x] Verify ServiceMonitor scraping (Prometheus target UP)
- [x] Verify PrometheusRule loaded (4 alerts in Prometheus UI)
- [x] Verify Vault metrics queryable

**Phase 3: Create Grafana Dashboards**
- [ ] Access Grafana UI (port-forward)
- [ ] Create Vault Health Overview dashboard
  - [ ] Panel: Seal Status (Stat)
  - [ ] Panel: Memory Usage (Gauge)
  - [ ] Panel: Memory Trend (Graph)
  - [ ] Panel: Request Rate (Graph)
  - [ ] Panel: Response Latency (Graph)
  - [ ] Panel: Active Tokens (Stat)
  - [ ] Panel: Uptime (Stat)
- [ ] Export Health dashboard JSON
- [ ] Update dashboards/vault-health.json
- [ ] Create Vault Blast Radius dashboard
  - [ ] Panel: Failing ExternalSecrets (Stat)
  - [ ] Panel: ExternalSecrets by Namespace (Bar chart)
  - [ ] Panel: ExternalSecret Details (Table)
  - [ ] Panel: Sync Failure Rate (Graph)
  - [ ] Panel: Vault Seal Events (Graph with annotations)
- [ ] Export Blast Radius dashboard JSON
- [ ] Update dashboards/vault-blast-radius.json
- [ ] Commit and push to Git
- [ ] ArgoCD syncs, ConfigMaps updated
- [ ] Verify dashboards imported in Grafana UI
- [ ] Verify dashboard panels populate with data

**Phase 4: Alert Testing & Tuning**
- [ ] Test VaultSealed alert
  - [ ] Seal Vault
  - [ ] Wait 1 minute
  - [ ] Verify alert fires in Prometheus
  - [ ] Verify alert in Alertmanager
  - [ ] Check Pushover notification received
  - [ ] Unseal Vault
  - [ ] Verify alert resolves
- [ ] Test ExternalSecretSyncFailure alert
  - [ ] Create broken ExternalSecret
  - [ ] Wait 5 minutes
  - [ ] Verify alert fires
  - [ ] Check Pushover notification
  - [ ] Delete broken ExternalSecret
  - [ ] Verify alert resolves
- [ ] Verify VaultTokenExpiringSoon configuration
  - [ ] Check token creation date accurate
  - [ ] Calculate expiration date
  - [ ] Confirm alert logic correct
- [ ] Tune thresholds if needed
  - [ ] VaultHighMemory threshold (0.90 vs 0.95)
  - [ ] ExternalSecretSyncFailure waitDuration (5m vs 10m)
- [ ] Run full validation script
- [ ] Verify all 13 automated checks pass
- [ ] Complete manual verification checklist

**Final Steps**
- [ ] Update GITOPS.md with monitoring pattern (if new pattern established)
- [ ] Document any threshold tuning in values.yaml comments
- [ ] Verify all phases complete and validated
- [ ] Mark story as Complete

---

## Migration Strategy

**No migration required** - This is a new deployment, not a modification of existing infrastructure.

**Impact on existing deployments**:
- ✅ **Vault**: Configuration change (telemetry enabled), requires pod restart and unseal
- ✅ **kube-prometheus-stack**: No changes, monitoring resources added
- ✅ **Other components**: No impact, monitoring is passive observation

**Backwards compatibility**:
- ✅ Vault telemetry is additive (doesn't break existing functionality)
- ✅ ServiceMonitor and PrometheusRule are new resources (no conflicts)
- ✅ Dashboards are new (no overwrites)

**Rollback safety**:
- ✅ Each phase can be rolled back independently
- ✅ Vault telemetry can be removed without data loss
- ✅ Monitoring resources can be deleted without affecting Vault

---

## Security Considerations

**Metrics endpoint**:
- ✅ Unauthenticated access to `/v1/sys/metrics` endpoint
- ✅ Metrics contain no sensitive data (seal status, resource usage, request counts)
- ✅ Standard practice for Prometheus metrics endpoints

**Cross-namespace access**:
- ✅ ServiceMonitor in `observability` scrapes Vault in `security`
- ✅ Prometheus ServiceAccount already has ClusterRole for scraping all namespaces
- ✅ No new RBAC required

**Alert content**:
- ✅ Alerts contain namespace, pod name, metric values
- ✅ No secrets or sensitive data in alert annotations
- ✅ Runbook URLs point to public documentation

**Dashboards**:
- ✅ Grafana authentication required to view dashboards
- ✅ Dashboard queries don't expose secrets
- ✅ ConfigMaps contain only dashboard JSON (no secrets)

**Pushover notifications**:
- ⚠️ Pushover credentials already configured in kube-prometheus-stack
- ⚠️ Potential circular dependency if credentials stored in Vault (accepted limitation)
- ✅ Alerts don't contain sensitive data in notification content

---

## Disaster Recovery

**Backup strategy**:
- ❌ **No automated backups implemented** (out of scope for this story)
- ✅ Manual backup procedures documented in infrastructure/security/vault/README.md
- ✅ Storage class has Retain policy (PV survives PVC deletion)

**Recovery scenarios**:

**Scenario 1: Vault monitoring broken (ServiceMonitor/PrometheusRule deleted)**:
- **Recovery**: ArgoCD syncs from Git, recreates resources
- **RTO**: ~2 minutes (ArgoCD sync cycle)
- **Impact**: Temporary loss of metrics and alerts

**Scenario 2: Vault sealed (operational issue, not DR)**:
- **Detection**: VaultSealed alert fires within 1 minute
- **Recovery**: Unseal with 3 unseal keys (manual procedure)
- **RTO**: 5 minutes (if keys available)
- **Impact**: Vault unavailable, ArgoCD syncs fail, ExternalSecrets can't refresh

**Scenario 3: Vault data loss (PVC deleted)**:
- **Detection**: Vault fails to start, metrics disappear
- **Recovery**: Restore from backup (manual procedures in Vault README)
- **RTO**: 1-2 hours (manual restore, if backup exists)
- **Impact**: All secrets lost until restore completes
- ⚠️ **Limitation**: No automated backups, manual procedures untested

**Monitoring recovery validation**:
- ✅ After any recovery, run `./validate.sh` to verify monitoring restored
- ✅ Check Prometheus targets, alert rules, and dashboard visibility
- ✅ Verify metrics flowing and alerts functional

**Recommendation**: Implement automated Vault backups as separate work to reduce RTO and ensure recoverability.

---

## Open Questions Resolved

All open questions from functional spec have been addressed:

1. ✅ **Does external-secrets-operator expose Prometheus metrics?** - Using kube-state-metrics as fallback (validation checks for both)
2. ✅ **How to monitor vals token TTL?** - Time-based alerting using documented creation date (simple, sufficient for 1-year TTL)
3. ✅ **Is Pushover configuration dependent on Vault secrets?** - Accepted potential circular dependency (monitoring still valuable, Pushover credentials cached in K8s secret)
4. ✅ **Dashboard organization preference?** - Two separate dashboards (Health Overview + Blast Radius)
5. ✅ **Should we monitor Vault certificate expiration?** - No, Vault uses HTTP (no TLS), cert-manager handles cert expiration if TLS added later
6. ✅ **Alert threshold tuning?** - Starting with 90% memory, 5m ExternalSecret wait, 7 days token warning; Phase 4 allows tuning based on operational experience
7. ✅ **Grafana sidecar configuration?** - Validation checks if enabled, warns if not (manual import required)
8. ✅ **Vault telemetry configuration security?** - Unauthenticated metrics acceptable (standard practice, no sensitive data)

---

## Next Steps

**After story completion:**
1. Monitor alert frequency and tune thresholds if needed
2. Quarterly review of token expiration date accuracy
3. Consider implementing automated Vault backups (separate story)
4. Evaluate custom token TTL exporter if token rotation becomes frequent
5. Add vals failure detection if ArgoCD exposes relevant metrics (monitor for feature)

**Related future work:**
- **Vault DR automation** - Implement automated backups, test restore procedures
- **Generic platform health** - Enhance kube-prometheus-stack with missing alerts (ContainerMemoryHigh)
- **Monitoring for other infrastructure components** - Apply vault-monitoring pattern to other critical infrastructure (ArgoCD, external-secrets, democratic-csi)
