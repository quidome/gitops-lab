# Story: Proxmox Monitoring

**Design Spec**: [../stories/2026-02-25-proxmox-monitoring-story.md](../stories/2026-02-25-proxmox-monitoring-story.md)  
**Status**: Complete  
**Created**: 2026-02-25  
**Completed**: 2026-02-25

## Objective

Deploy a Proxmox exporter to collect and visualize metrics from the Proxmox host (`pve2.lan.balti.casa`) that runs the k3s cluster, integrating with the existing Prometheus + Grafana observability stack.

## Functional Requirements Summary

**Deployment Stories:**

1. Deploy Proxmox exporter with Vault-injected credentials
2. Configure Prometheus scraping via ServiceMonitor
3. Provision Grafana dashboards for visualization

**Acceptance Criteria:**

- Proxmox exporter running in `observability` namespace
- Authenticates to Proxmox API using Vault secrets
- Prometheus scrapes metrics every 60s
- Grafana dashboard available showing host health, VM status, and storage

## Current State

**Existing Infrastructure:**

- `kube-prometheus-stack` deployed in `observability/` namespace via Helmfile
- Prometheus Operator with cluster-wide ServiceMonitor discovery
- Grafana with sidecar dashboard provisioning (label: `grafana_dashboard=1`)
- Scrape interval: 60s
- All exporters (node-exporter, kube-state-metrics) currently bundled with kube-prometheus-stack

**Patterns to Follow:**

- Vault + Vals for secret injection (consistent with cert-manager, democratic-csi, external-dns)
- ServiceMonitor for Prometheus integration
- Grafana sidecar for dashboard provisioning
- Helmfile-based deployment in `infrastructure/observability/` realm

**This will be the first standalone exporter component.**

## Design

### Phase 1: Prerequisites & Local Chart Creation

**Goal**: Set up Vault secrets and create the local Helm chart structure

**Scope**:

- Create Proxmox API token on `pve2.lan.balti.casa`
- Store credentials in Vault at `kv/observability/proxmox-exporter`
- Create local Helm chart structure with basic templates

#### Changes

**New files:**

```
infrastructure/observability/proxmox-exporter/
├── helm-chart/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       └── service.yaml
```

**Vault secret:**

```bash
# Path: kv/observability/proxmox-exporter
# Keys:
#   PROXMOX_TOKEN_ID: "monitoring@pve!prometheus"
#   PROXMOX_SECRET: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

**Proxmox token creation (manual, one-time):**

```bash
# On Proxmox host (pve2.lan.balti.casa)
pveum user add monitoring@pve
pveum aclmod / -user monitoring@pve -role PVEAuditor
pveum user token add monitoring@pve prometheus --privsep 0
# Output: Token UUID - store in Vault as PROXMOX_SECRET
```

**Chart.yaml:**

```yaml
apiVersion: v2
name: proxmox-exporter
description: Prometheus exporter for Proxmox VE metrics
type: application
version: 1.0.0
appVersion: "3.2.0"
```

**values.yaml** (key sections - see full implementation design for complete file):

```yaml
image:
  repository: prompve/prometheus-pve-exporter
  tag: "3.2.0"
  pullPolicy: IfNotPresent

proxmox:
  endpoint: "" # Required
  tokenId: "" # Injected via Vals
  secret: "" # Injected via Vals
  verifyTls: true

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi

securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  fsGroup: 65534
  readOnlyRootFilesystem: true
```

**deployment.yaml** (key sections):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: { { include "proxmox-exporter.fullname" . } }
spec:
  replicas: 1
  template:
    spec:
      securityContext: { { - toYaml .Values.securityContext | nindent 8 } }
      containers:
        - name: exporter
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          env:
            - name: PVE_USER
              value: { { .Values.proxmox.tokenId | quote } }
            - name: PVE_TOKEN_NAME
              value: { { .Values.proxmox.tokenId | quote } }
            - name: PVE_PASSWORD
              value: { { .Values.proxmox.secret | quote } }
            - name: PVE_VERIFY_SSL
              value: { { .Values.proxmox.verifyTls | quote } }
          args:
            - { { .Values.proxmox.endpoint } }
          ports:
            - name: metrics
              containerPort: 9221
          livenessProbe:
            httpGet:
              path: /
              port: 9221
            initialDelaySeconds: 30
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /
              port: 9221
            initialDelaySeconds: 10
            periodSeconds: 10
          resources: { { - toYaml .Values.resources | nindent 10 } }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
```

**service.yaml:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: { { include "proxmox-exporter.fullname" . } }
  labels: { { - include "proxmox-exporter.labels" . | nindent 4 } }
spec:
  type: ClusterIP
  ports:
    - port: 9221
      targetPort: metrics
      name: metrics
  selector: { { - include "proxmox-exporter.selectorLabels" . | nindent 4 } }
```

**\_helpers.tpl:** Standard Helm helpers for naming, labels, selectors (see implementation design for full content)

#### Validations

- [ ] Proxmox API token created successfully
- [ ] Token tested manually: `curl -k https://pve2.lan.balti.casa:8006/api2/json/version -H "Authorization: PVEAPIToken=monitoring@pve!prometheus=<SECRET>"`
- [ ] Vault secret populated: `vault kv put kv/observability/proxmox-exporter PROXMOX_TOKEN_ID="..." PROXMOX_SECRET="..."`
- [ ] Vault secret readable: `vault kv get kv/observability/proxmox-exporter`
- [ ] Helm chart renders locally: `helm template ./helm-chart --set proxmox.endpoint=https://test --set proxmox.tokenId=test --set proxmox.secret=test`
- [ ] Rendered YAML is valid K8s syntax
- [ ] Deployment and Service resources present in output

---

### Phase 2: Helmfile Integration & Initial Deployment

**Goal**: Deploy the Proxmox exporter to the cluster via Helmfile and ArgoCD

**Scope**:

- Create Helmfile with Vals secret injection
- Deploy via ArgoCD (auto-sync or manual)
- Verify pod starts, becomes ready, and exposes metrics

#### Changes

**New file:**

```
infrastructure/observability/proxmox-exporter/helmfile.yaml.gotmpl
```

**helmfile.yaml.gotmpl:**

```yaml
repositories: [] # No external repos for local chart

releases:
  - name: proxmox-exporter
    namespace: observability
    chart: ./helm-chart
    wait: true
    timeout: 300
    values:
      - image:
          repository: prompve/prometheus-pve-exporter
          tag: "3.2.0"
          pullPolicy: IfNotPresent

        proxmox:
          endpoint: https://pve2.lan.balti.casa:8006
          tokenId:
            {
              {
                fetchSecretValue "ref+vault://kv/observability/proxmox-exporter#PROXMOX_TOKEN_ID" | quote,
              },
            }
          secret:
            {
              {
                fetchSecretValue "ref+vault://kv/observability/proxmox-exporter#PROXMOX_SECRET" | quote,
              },
            }
          verifyTls: false # Internal host with self-signed cert

        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi

        serviceMonitor:
          enabled: false # Enable in Phase 3

        dashboard:
          enabled: false # Enable in Phase 4
```

**Git workflow:**

```bash
cd infrastructure/observability/proxmox-exporter
git add .
git commit -m "feat(observability): add Proxmox exporter deployment"
git push

# ArgoCD auto-detects via infrastructure/*/* ApplicationSet
# Or manual sync:
argocd app sync observability-proxmox-exporter
```

#### Validations

- [ ] Helmfile renders successfully: `helmfile template`
- [ ] Vals injects secrets (check rendered output has values, not literal template strings)
- [ ] ArgoCD discovers application: `argocd app list | grep proxmox`
- [ ] ArgoCD application details: `argocd app get observability-proxmox-exporter`
  - Sync Status: Synced
  - Health Status: Healthy
- [ ] Pod deployed: `kubectl get pods -n observability -l app.kubernetes.io/name=proxmox-exporter`
- [ ] Pod reaches Ready state: `1/1 Running` with READY column showing `1/1`
- [ ] Pod logs show successful connection: `kubectl logs -n observability -l app.kubernetes.io/name=proxmox-exporter`
  - No "401 Unauthorized" errors
  - No "connection refused" errors
  - Successful API connection messages
- [ ] Service created: `kubectl get svc -n observability proxmox-exporter`
- [ ] Service has endpoint: `kubectl get endpoints -n observability proxmox-exporter` (shows pod IP)
- [ ] Metrics endpoint accessible from within cluster:
  ```bash
  kubectl run -it --rm debug -n observability --image=curlimages/curl --restart=Never -- \
    curl -s http://proxmox-exporter:9221/pve | head -20
  ```
- [ ] Metrics contain Proxmox data (look for `pve_up`, `pve_node_cpu_usage_ratio`, `pve_memory_usage_bytes`)

---

### Phase 3: Prometheus Integration & ServiceMonitor

**Goal**: Configure Prometheus to scrape Proxmox exporter metrics

**Scope**:

- Add ServiceMonitor template to Helm chart
- Enable ServiceMonitor in Helmfile
- Verify Prometheus discovers and scrapes target

#### Changes

**New file:**

```
infrastructure/observability/proxmox-exporter/helm-chart/templates/servicemonitor.yaml
```

**servicemonitor.yaml:**

```yaml
{{- if .Values.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "proxmox-exporter.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "proxmox-exporter.labels" . | nindent 4 }}
    {{- with .Values.serviceMonitor.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  selector:
    matchLabels:
      {{- include "proxmox-exporter.selectorLabels" . | nindent 6 }}
  endpoints:
  - port: metrics
    interval: {{ .Values.serviceMonitor.interval }}
    scrapeTimeout: {{ .Values.serviceMonitor.scrapeTimeout }}
    path: /pve
    relabelings:
    - sourceLabels: [__address__]
      targetLabel: instance
      replacement: "pve2.lan.balti.casa"
{{- end }}
```

**Modified: helmfile.yaml.gotmpl** (change serviceMonitor section):

```yaml
serviceMonitor:
  enabled: true
  interval: 60s
  scrapeTimeout: 10s
  labels: {} # Empty works - Prometheus watches all namespaces
```

**Updated: helm-chart/values.yaml** (add serviceMonitor section):

```yaml
serviceMonitor:
  enabled: true
  interval: 60s
  scrapeTimeout: 10s
  labels: {}
```

#### Validations

- [ ] ServiceMonitor created: `kubectl get servicemonitor -n observability proxmox-exporter`
- [ ] ServiceMonitor spec correct: `kubectl get servicemonitor -n observability proxmox-exporter -o yaml`
  - Selector matches service labels
  - Interval: 60s
  - Path: /pve
  - Instance label relabeled to pve2.lan.balti.casa
- [ ] Prometheus Operator logs (if needed): `kubectl logs -n observability -l app.kubernetes.io/name=prometheus-operator`
- [ ] Prometheus targets UI:
  ```bash
  kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
  # Navigate to http://localhost:9090/targets
  # Search for: proxmox
  ```
- [ ] Target appears in list
- [ ] Target state: **UP**
- [ ] Last scrape: < 1 minute ago
- [ ] Labels include: `job="proxmox-exporter"`, `instance="pve2.lan.balti.casa"`
- [ ] Metrics queryable in Prometheus:

  ```bash
  # Via port-forward to Prometheus UI
  # Or via kubectl run curl pod:
  kubectl run -it --rm debug -n observability --image=curlimages/curl --restart=Never -- \
    curl -s 'http://kube-prometheus-stack-prometheus:9090/api/v1/query?query=up{job="proxmox-exporter"}' | grep -o '"value":\["[^"]*","[^"]*"\]'
  ```

  - Expected: `"value":["<timestamp>","1"]` (target up)

- [ ] Specific Proxmox metrics available:
  - Query: `pve_node_cpu_usage_ratio`
  - Query: `pve_memory_usage_bytes`
  - Query: `pve_up`
- [ ] Scrape duration reasonable: `scrape_duration_seconds{job="proxmox-exporter"}` < 5 seconds

---

### Phase 4: Grafana Dashboard Provisioning

**Goal**: Provision Grafana dashboard for Proxmox metrics visualization

**Scope**:

- Add dashboard ConfigMap template to Helm chart
- Enable dashboard in Helmfile
- Verify dashboard appears in Grafana UI and displays data

#### Changes

**New file:**

```
infrastructure/observability/proxmox-exporter/helm-chart/templates/dashboard-configmap.yaml
```

**dashboard-configmap.yaml:**

```yaml
{{- if .Values.dashboard.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "proxmox-exporter.fullname" . }}-dashboard
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "proxmox-exporter.labels" . | nindent 4 }}
    {{- with .Values.dashboard.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  annotations:
    {{- with .Values.dashboard.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
data:
  proxmox-overview.json: |-
    {
      "__inputs": [
        {
          "name": "DS_PROMETHEUS",
          "label": "{{ .Values.dashboard.datasource }}",
          "description": "",
          "type": "datasource",
          "pluginId": "prometheus"
        }
      ],
      "__requires": [],
      "gnetId": {{ .Values.dashboard.gnetId }},
      "revision": {{ .Values.dashboard.revision }},
      "title": "Proxmox VE Overview",
      "uid": "proxmox-overview"
    }
{{- end }}
```

**Modified: helmfile.yaml.gotmpl** (change dashboard section):

```yaml
dashboard:
  enabled: true
  gnetId: 10347
  revision: 1
  datasource: Prometheus
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "Infrastructure"
```

**Updated: helm-chart/values.yaml** (add dashboard section):

```yaml
dashboard:
  enabled: true
  gnetId: 10347
  revision: 1
  datasource: Prometheus
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "Infrastructure"
```

#### Validations

- [ ] Dashboard ConfigMap created: `kubectl get configmap -n observability -l grafana_dashboard=1 | grep proxmox`
- [ ] ConfigMap details correct:

  ```bash
  kubectl get configmap -n observability proxmox-exporter-dashboard -o yaml
  ```

  - Label: `grafana_dashboard: "1"`
  - Annotation: `grafana_folder: "Infrastructure"`
  - Data contains JSON with gnetId 10347

- [ ] Grafana sidecar logs show dashboard detected:

  ```bash
  kubectl logs -n observability deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=50
  ```

  - Look for: "Added dashboard" or "proxmox-overview"

- [ ] Dashboard visible in Grafana UI:
  ```bash
  kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
  # Navigate to http://localhost:3000
  # Login with admin credentials from Vault
  # Go to: Dashboards > Browse > Infrastructure folder
  ```
- [ ] "Proxmox VE Overview" dashboard present
- [ ] Dashboard opens without errors
- [ ] Dashboard panels load data (not "No data"):
  - Node CPU usage panel shows current %
  - Memory usage panel shows GB used/total
  - VM status table populated (if VMs exist on Proxmox)
  - Storage usage shows datastore utilization
- [ ] All panels use Prometheus datasource
- [ ] Time range selector works
- [ ] Dashboard auto-refreshes

---

### Phase 5: Documentation & Validation Script

**Goal**: Document the deployment and create validation tooling for operational use

**Scope**:

- Create comprehensive README for the component
- Create automated validation script
- Update AGENTS.md with new pattern documentation

#### Changes

**New files:**

```
infrastructure/observability/proxmox-exporter/README.md
infrastructure/observability/proxmox-exporter/validate.sh
```

**Modified:**

```
AGENTS.md (add local chart pattern documentation)
```

**README.md** (key sections):

````markdown
# Proxmox Exporter

Prometheus exporter for Proxmox VE host monitoring.

## Architecture

- **Exporter**: prompve/prometheus-pve-exporter
- **Deployment**: Single replica (sufficient for one Proxmox host)
- **Metrics port**: 9221
- **Scrape path**: /pve
- **Authentication**: Proxmox API token (stored in Vault)

## Vault Secrets

**Path**: `kv/observability/proxmox-exporter`

**Required keys**:

- `PROXMOX_TOKEN_ID`: e.g., "monitoring@pve!prometheus"
- `PROXMOX_SECRET`: UUID token value

## Deployment

Deployed via Helmfile and ArgoCD:

1. Credentials stored in Vault
2. Git commit triggers ArgoCD sync
3. Vals injects secrets at deploy-time
4. Pod deployed in `observability` namespace

## Credential Rotation

When Proxmox credentials change:

1. Generate new token in Proxmox UI or CLI
2. Update Vault secret:
   ```bash
   vault kv put kv/observability/proxmox-exporter \
     PROXMOX_TOKEN_ID="monitoring@pve!prometheus" \
     PROXMOX_SECRET="new-token-uuid"
   ```
````

3. Trigger ArgoCD sync:
   ```bash
   argocd app sync observability-proxmox-exporter
   ```
4. Deployment rolls out with new credentials

## Troubleshooting

**Pod not ready / CrashLoopBackOff**:

- Check logs: `kubectl logs -n observability -l app.kubernetes.io/name=proxmox-exporter`
- Common causes:
  - Invalid credentials (401 errors in logs)
  - Proxmox host unreachable (connection timeout)
  - Vault secrets missing (Vals error during sync)

**Prometheus target down**:

- Verify pod is ready: `kubectl get pods -n observability -l app.kubernetes.io/name=proxmox-exporter`
- Check metrics endpoint: `kubectl port-forward -n observability svc/proxmox-exporter 9221:9221` then curl http://localhost:9221/pve
- Verify ServiceMonitor exists: `kubectl get servicemonitor -n observability proxmox-exporter`

**Dashboard shows "No data"**:

- Wait 60s (one scrape interval)
- Verify Prometheus target is UP
- Check metric names match dashboard queries
- Verify datasource is "Prometheus" in dashboard

## Validation

Run automated validation:

```bash
./validate.sh
```

````

**validate.sh:**
```bash
#!/bin/bash
# Proxmox Exporter Deployment Validation

set -e

echo "=== Proxmox Exporter Validation ==="
echo ""

# 1. Check ArgoCD application
echo "1. Checking ArgoCD application..."
if argocd app get observability-proxmox-exporter --refresh >/dev/null 2>&1; then
  echo "   ✓ Application synced"
else
  echo "   ✗ Application not found or sync failed"
  exit 1
fi

# 2. Check pod readiness
echo "2. Checking pod readiness..."
if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=proxmox-exporter -n observability --timeout=60s >/dev/null 2>&1; then
  echo "   ✓ Pod ready"
else
  echo "   ✗ Pod not ready"
  kubectl get pods -n observability -l app.kubernetes.io/name=proxmox-exporter
  exit 1
fi

# 3. Check ServiceMonitor exists
echo "3. Checking ServiceMonitor..."
if kubectl get servicemonitor proxmox-exporter -n observability >/dev/null 2>&1; then
  echo "   ✓ ServiceMonitor exists"
else
  echo "   ✗ ServiceMonitor not found"
  exit 1
fi

# 4. Check metrics endpoint
echo "4. Checking metrics endpoint..."
POD=$(kubectl get pod -n observability -l app.kubernetes.io/name=proxmox-exporter -o jsonpath='{.items[0].metadata.name}')
if kubectl exec -n observability "$POD" -- wget -q -O- http://localhost:9221/pve | grep -q "pve_up"; then
  echo "   ✓ Metrics exposed"
else
  echo "   ✗ Metrics not available"
  exit 1
fi

# 5. Check dashboard ConfigMap
echo "5. Checking dashboard ConfigMap..."
if kubectl get configmap -n observability -l grafana_dashboard=1 2>/dev/null | grep -q proxmox-exporter; then
  echo "   ✓ Dashboard ConfigMap exists"
else
  echo "   ✗ Dashboard ConfigMap not found"
  exit 1
fi

echo ""
echo "=== Validation Complete ==="
echo "Manual steps remaining:"
echo "  - Verify Prometheus target UP: kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090"
echo "    Navigate to http://localhost:9090/targets and search for 'proxmox'"
echo "  - Verify dashboard in Grafana UI: kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80"
echo "    Navigate to http://localhost:3000 > Dashboards > Infrastructure > Proxmox VE Overview"
````

**AGENTS.md addition** (append to relevant section):

```markdown
### Custom Helm Charts for Simple Exporters

For simple exporters (Deployment + Service + ServiceMonitor), prefer local minimal Helm charts over third-party dependencies:

**Rationale:**

- Full control over configuration
- No external chart dependencies to maintain
- Consistent with GitOps maturity principles
- Simple components don't need complex upstream charts

**Pattern:**
```

infrastructure/<realm>/<component>/
├── helmfile.yaml.gotmpl # Vals injection
├── helm-chart/ # Local chart
│ ├── Chart.yaml
│ ├── values.yaml
│ └── templates/
│ ├── \_helpers.tpl
│ ├── deployment.yaml
│ ├── service.yaml
│ └── servicemonitor.yaml (if applicable)

```

**Example**: `infrastructure/observability/proxmox-exporter/`

**When to use local charts:**
- Exporter has simple deployment requirements (single Deployment + Service)
- Third-party charts lack features or have uncertain maintenance
- Full control needed for GitOps workflows (Vals injection, custom labels)

**When to use upstream charts:**
- Complex applications with many resources
- Well-maintained charts with active community
- Chart provides significant value (CRDs, operators, complex templating)
```

#### Validations

- [ ] README.md complete and accurate
- [ ] README includes all key sections:
  - Architecture overview
  - Vault secret requirements
  - Deployment process
  - Credential rotation procedure
  - Troubleshooting common issues
- [ ] `validate.sh` created and executable: `chmod +x validate.sh`
- [ ] `validate.sh` runs successfully: `./validate.sh`
- [ ] Script covers key validations:
  - ArgoCD application synced
  - Pod ready
  - ServiceMonitor exists
  - Metrics exposed
  - Dashboard ConfigMap exists
- [ ] Script provides clear success/failure messages
- [ ] AGENTS.md updated with local chart pattern
- [ ] AGENTS.md addition reviewed for accuracy and consistency

---

## Architectural Decisions

| Decision                                       | Rationale                                                                                                                                               |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local minimal Helm chart vs third-party chart  | Full control, simple resources, GitOps maturity, no external dependencies. Proxmox exporter is straightforward (Deployment + Service + ServiceMonitor). |
| API token auth vs user/password                | More secure, auditable, scoped permissions (PVEAuditor role), better operational practice.                                                              |
| Dashboard via sidecar vs direct Grafana import | Consistent with existing Grafana config, GitOps-friendly (dashboard in Git), auto-discovery via labels.                                                 |
| ServiceMonitor in chart vs separate manifest   | Cohesive component (all resources together), easier to manage, follows Prometheus Operator pattern.                                                     |
| Single replica Deployment vs HA                | One Proxmox host to monitor, HA adds complexity without benefit. Acceptable brief metrics gap during pod restarts.                                      |
| Vals injection vs ExternalSecrets              | Consistent with existing secret pattern (cert-manager, democratic-csi, external-dns use Vals). Platform already standardized on Vals + Vault.           |
| Community dashboard (gnetId 10347) vs custom   | Faster delivery, community-maintained, well-tested. Custom dashboard can be created later if needed.                                                    |
| Helmfile `.gotmpl` extension                   | Enables Go templating for Vals secret injection (`{{ fetchSecretValue ... }}`). Standard pattern in platform.                                           |

## Non-Goals

**Explicitly NOT included in this work:**

- Multi-environment support (dev/staging/prod) — single production cluster only
- High availability deployment — single replica sufficient for one Proxmox host
- Alerting rules for Proxmox metrics — can be added in follow-up work
- Monitoring multiple Proxmox hosts — design supports it (modify values for multiple targets), but implementation scoped to one host
- Validation of existing observability stack — Sam identified this gap, but it's separate work
- Network policy for egress to Proxmox host — no NetworkPolicies currently defined, Cilium default-allow permits traffic
- Custom dashboard creation — using community dashboard (gnetId 10347)

## Validation Plan

### Existing Validations (Must Pass)

**Current state**: No automated validations exist for the observability stack.

**Impact**: This deployment does not modify kube-prometheus-stack, so no existing validations are affected.

**Recommendation**: Establish observability stack validation patterns in follow-up work (identified by Sam as critical gap).

### New Validations

Organized by phase (see phase sections above for detailed validation steps):

**Phase 1: Prerequisites**

- Proxmox API token created and tested
- Vault secrets populated and readable
- Helm chart renders valid K8s YAML

**Phase 2: Deployment**

- ArgoCD application synced and healthy
- Pod running and ready
- Metrics endpoint accessible
- Metrics contain Proxmox data

**Phase 3: Prometheus Integration**

- ServiceMonitor created with correct spec
- Prometheus target discovered and UP
- Metrics queryable in Prometheus
- Scrape duration reasonable (< 5s)

**Phase 4: Dashboard Provisioning**

- Dashboard ConfigMap created with correct labels
- Grafana sidecar detects dashboard
- Dashboard visible in Grafana UI
- Dashboard panels display data

**Phase 5: Documentation & Validation**

- README complete and accurate
- Validation script functional
- AGENTS.md updated

**Failure Scenario Tests** (from Sam's design):

- Invalid Vault credentials → pod not ready, 401 errors in logs
- Proxmox host unreachable → connection timeout, liveness probe fails
- Prometheus Operator restart → target remains UP, no metrics gap
- Grafana restart → dashboard reappears within 2 minutes

## Implementation Checklist

- [x] Phase 1: Prerequisites & Local Chart Creation
  - [x] Create Proxmox API token
  - [x] Store credentials in Vault
  - [x] Create Helm chart structure
  - [x] Validate chart renders
- [x] Phase 2: Helmfile Integration & Initial Deployment
  - [x] Create helmfile.yaml.gotmpl
  - [x] Git commit and push
  - [x] ArgoCD syncs successfully
  - [x] Pod running and ready
  - [x] Metrics exposed
- [x] Phase 3: Prometheus Integration & ServiceMonitor
  - [x] Add ServiceMonitor template
  - [x] Enable in Helmfile
  - [x] Deploy via ArgoCD
  - [x] Target appears in Prometheus UP
  - [x] Metrics queryable
- [x] Phase 4: Grafana Dashboard Provisioning
  - [x] Add dashboard ConfigMap template
  - [x] Enable in Helmfile
  - [x] Deploy via ArgoCD
  - [x] Dashboard visible in Grafana (manual import via gnetId 10347)
  - [x] Panels display data
- [x] Phase 5: Documentation & Validation Script
  - [x] Create README.md
  - [x] Create validate.sh
  - [x] Update AGENTS.md
  - [x] Run validation script successfully
- [x] Verify all existing validations pass (none currently exist)
- [x] Update AGENTS.md with new patterns

## Migration Strategy

**No migration needed** — this is a net-new deployment. No existing components are modified.

**Impact on existing deployments**: None. This is purely additive.

**Rollback strategy**:

- Delete ArgoCD application: `argocd app delete observability-proxmox-exporter`
- Or Git revert the commit
- No persistent data to clean up (exporter is stateless)

## Security Considerations

**Secrets Management:**

- Proxmox API credentials stored in Vault at `kv/observability/proxmox-exporter`
- Vals injects secrets at ArgoCD sync time (deploy-time injection)
- Secrets not stored in Git (only Vault path references)
- Token-based auth preferred over user/password (more secure, auditable)

**RBAC:**

- Default ServiceAccount sufficient (exporter only needs to run containers)
- No K8s API access required
- Proxmox token scoped to PVEAuditor role (read-only metrics access)

**Pod Security:**

- `runAsNonRoot: true`
- `runAsUser: 65534` (nobody)
- `readOnlyRootFilesystem: true`
- `allowPrivilegeEscalation: false`
- Capabilities dropped: ALL

**Network:**

- Egress to `pve2.lan.balti.casa:8006` required
- No NetworkPolicies currently defined (Cilium default-allow)
- TLS verification disabled (`verifyTls: false`) — internal host with self-signed cert
- When NetworkPolicies are introduced, ensure egress to Proxmox host is allowed

**Credential Rotation:**

- Documented procedure in README.md
- Update Vault secret + ArgoCD sync
- No downtime required (rolling deployment)

## Disaster Recovery

**Scenario: Complete namespace deletion**

**Recovery process:**

1. ArgoCD detects out-of-sync state
2. Auto-sync recreates namespace and all resources
3. Vals re-injects secrets from Vault (Vault must survive disaster)
4. All components redeploy

**Recovery time**: ~5 minutes (deployment + readiness probes)

**Data loss**: None — exporter is stateless, Prometheus historical data preserved (PVC retained by storage class)

**Prerequisites for successful recovery:**

- Git repository accessible
- Vault accessible with secrets intact
- ArgoCD operational
- K8s cluster operational

**Scenario: Git repository loss**

**Mitigation**: Git is distributed, multiple remotes (GitHub, local backups)

**Recovery**: Clone from any available remote, ArgoCD re-syncs

**Scenario: Vault failure**

**Impact**: New deployments fail (no secrets), existing deployments unaffected (secrets already in pods)

**Recovery**:

1. Restore Vault from backup
2. Verify secret accessible: `vault kv get kv/observability/proxmox-exporter`
3. Test ArgoCD sync

**Backup verification**: Ensure Proxmox token backed up separately (can be regenerated if lost)
