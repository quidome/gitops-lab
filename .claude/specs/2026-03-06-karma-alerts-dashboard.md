# Story: Karma Alerts Dashboard

**Design Spec**: `~/store/gitops-designs/2026-03-06-karma-alerts-dashboard.md`
**Status**: Implemented
**Created**: 2026-03-06

## Objective

Deploy Karma as an alerts dashboard to view, acknowledge, and manage silences for AlertManager alerts, accessible from the home network at `alerts.quido.me`.

## Functional Requirements Summary

From the design spec, four deployment stories:

1. **View All Firing Alerts**: Dashboard shows all alerts from AlertManager in real-time with logical grouping
2. **Acknowledge Alerts**: One-click ACK creates short-lived silences (30m default)
3. **Schedule Downtime**: Create, view, and expire silences for planned maintenance
4. **Access from Home Network**: Accessible at `alerts.quido.me` via browser without kubectl

## Current State

- **AlertManager**: Running as part of kube-prometheus-stack in `observability` namespace
- **AlertManager service**: `alertmanager-operated.observability.svc.cluster.local:9093`
- **Gateway**: `gateway-internal` in `networking` namespace, IP `172.16.40.50`
- **No alerts dashboard**: Currently must use kubectl or basic AlertManager UI

## Design

### Phase 1: Deploy Karma

- **Goal**: Karma running in cluster, connected to AlertManager
- **Scope**: Create local Helm chart and deploy via Helmfile

#### Changes

Create directory structure:

```
infrastructure/observability/karma/
├── helmfile.yaml
└── helm-chart/
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── deployment.yaml
        ├── service.yaml
        └── configmap.yaml
```

**helm-chart/Chart.yaml:**
```yaml
apiVersion: v2
name: karma
description: Karma alerts dashboard for AlertManager
version: 0.1.0
appVersion: "0.120"
```

**helm-chart/values.yaml:**
```yaml
image:
  repository: ghcr.io/prymitive/karma
  tag: v0.120
  pullPolicy: IfNotPresent

config:
  alertmanager:
    interval: 30s
    servers:
      - name: k3s
        uri: http://alertmanager-operated.observability.svc.cluster.local:9093

  alertAcknowledgement:
    enabled: true
    duration: 30m
    author: operator
    comment: "ACK via Karma"

  listen:
    address: "0.0.0.0"
    port: 8080

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    memory: 64Mi

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

livenessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 5
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 5
  periodSeconds: 5
```

**helm-chart/templates/configmap.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
data:
  karma.yaml: |
    {{- toYaml .Values.config | nindent 4 }}
```

**helm-chart/templates/deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    spec:
      containers:
        - name: karma
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args:
            - --config.file=/etc/karma/karma.yaml
          ports:
            - name: http
              containerPort: {{ .Values.config.listen.port }}
              protocol: TCP
          volumeMounts:
            - name: config
              mountPath: /etc/karma
              readOnly: true
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.readinessProbe | nindent 12 }}
      volumes:
        - name: config
          configMap:
            name: {{ .Release.Name }}-config
```

**helm-chart/templates/service.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
      protocol: TCP
      name: http
  selector:
    app: {{ .Release.Name }}
```

**helmfile.yaml:**
```yaml
releases:
  - name: karma
    namespace: observability
    createNamespace: true
    chart: ./helm-chart
```

#### Validations

- [ ] `helmfile template` renders without errors
- [ ] Pod reaches Running state
- [ ] Readiness probe passes (`/health` returns 200)
- [ ] `kubectl port-forward svc/karma 8080:80 -n observability` shows Karma UI
- [ ] Karma shows AlertManager as connected (green status)
- [ ] Existing alerts appear in Karma

---

### Phase 2: Enable External Access

- **Goal**: Access Karma from home network at `alerts.quido.me`
- **Scope**: Add HTTPRoute and Pi-hole DNS entry

#### Changes

Add resources chart:

```
infrastructure/observability/karma/
├── helmfile.yaml          # Updated
├── helm-chart/
│   └── ...
└── resources/
    ├── Chart.yaml
    └── templates/
        └── httproute.yaml
```

**resources/Chart.yaml:**
```yaml
apiVersion: v2
name: karma-resources
description: HTTPRoute for Karma
version: 0.1.0
```

**resources/templates/httproute.yaml:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: karma
  labels:
    app: karma
    component: observability
spec:
  parentRefs:
    - name: gateway-internal
      namespace: networking
      group: gateway.networking.k8s.io
      kind: Gateway
  hostnames:
    - alerts.quido.me
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: karma
          port: 80
```

**helmfile.yaml (updated):**
```yaml
releases:
  - name: karma
    namespace: observability
    createNamespace: true
    chart: ./helm-chart

  - name: karma-resources
    namespace: observability
    chart: ./resources
    needs:
      - observability/karma
```

**Pi-hole DNS entry (manual):**
```
alerts.quido.me → 172.16.40.50
```

#### Validations

- [ ] HTTPRoute accepted: `kubectl get httproute karma -n observability` shows attached
- [ ] Pi-hole resolves `alerts.quido.me` to `172.16.40.50`
- [ ] Browser access to `https://alerts.quido.me` loads Karma UI
- [ ] ACK button creates silence in AlertManager
- [ ] Silence management works (create, view, expire)

---

## Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| Local minimal chart | Upstream chart landscape fragmented; Karma simple enough; matches platform pattern (proxmox-exporter, ntfy) |
| ConfigMap for config | Cleaner than env vars for complex config; supports full karma.yaml structure |
| Config checksum annotation | Ensures pod restarts when configuration changes |
| 30m ACK duration | Balance between "acknowledged" signal and auto-expiry for forgotten ACKs |
| No authentication | Network-level access control sufficient for home lab |
| Service port 80 | Consistent with other services; maps to container 8080 |

## Non-Goals

- Grafana navigation link (nice-to-have, can add later)
- Multiple AlertManager support (single cluster)
- Authentication/authorization (network access sufficient)
- ServiceMonitor for Karma metrics (can add later if needed)
- External/public exposure (internal only)

## Validation Plan

### Existing Validations (Must Pass)

After deployment, verify no regression:
- [ ] kube-prometheus-stack healthy
- [ ] AlertManager receiving alerts
- [ ] Grafana accessible
- [ ] ntfy functioning

### New Validations

**Phase 1:**
- [ ] Helm template renders cleanly
- [ ] Pod running and ready
- [ ] Karma connected to AlertManager
- [ ] Internal port-forward access works

**Phase 2:**
- [ ] HTTPRoute accepted by gateway
- [ ] DNS resolves correctly
- [ ] Browser access works
- [ ] ACK and silence functions work

### Failure Scenarios

| Scenario | Expected | Validation |
|----------|----------|------------|
| AlertManager down | Karma shows disconnected state | Stop AM, check Karma UI |
| AlertManager restart | Karma reconnects | Restart AM pod, verify recovery |
| Bad config | Pod fails with clear error | Deploy invalid config, check logs |

## Implementation Checklist

- [x] Phase 1: Deploy Karma with local chart
- [x] Phase 2: Add HTTPRoute and DNS entry
- [ ] Verify existing observability stack unaffected
- [ ] Test ACK and silence management end-to-end

## Migration Strategy

No migration needed — this is a new deployment. No existing resources affected.

## Security Considerations

- **Network access**: Internal only via gateway-internal
- **No authentication**: Acceptable for home lab; anyone on LAN can view/manage alerts
- **AlertManager access**: Karma creates silences via unauthenticated internal API
- **No K8s RBAC**: Karma doesn't access K8s API
- **No secrets**: No Vault integration needed

## Disaster Recovery

- **Source of truth**: Git (`infrastructure/observability/karma/`)
- **State**: None — Karma is stateless
- **Silences**: Stored in AlertManager, not Karma
- **Recovery**: Delete namespace resources, re-sync via ArgoCD
