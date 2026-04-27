# Story: Deploy UniFi Network Application

**Design Spec**: `../stories/2026-03-12-unifi-controller.md`
**Status**: Implementation Complete (pending deployment)
**Created**: 2026-03-12

## Objective

Deploy UniFi Network Application to manage two access points on VLAN 40, with web UI accessible via HTTPRoute and device communication via LoadBalancer service.

## Functional Requirements Summary

From the design spec:

1. **Deploy UniFi Controller**: Single-replica deployment with persistent storage, web UI at `unifi.quido.me`, device communication ports accessible to APs
2. **Adopt Access Points**: APs can discover controller via L2 or manual inform URL configuration

**Acceptance Criteria:**
- Controller runs as single-replica deployment
- Persistent storage preserves MongoDB data across restarts
- Web UI accessible via HTTPRoute at `unifi.quido.me`
- Device communication ports (8080, 3478/UDP, 10001/UDP) accessible via LoadBalancer
- Deployment follows GitOps conventions (Helmfile, local chart)

## Current State

- **Realm**: `network-management` does not exist — this is a new realm
- **Namespace**: `network-management` will be created by ArgoCD (`CreateNamespace=true`)
- **ApplicationSet**: Existing `applications/applicationset.yaml` will auto-discover `applications/network-management/unifi-controller/`

No existing deployments or charts to modify.

## Design

### Phase 1: Chart Structure

**Goal:** Create the local Helm chart with core Kubernetes resources

**Scope:**
- Helm chart structure with Deployment, PVC, and Services
- Chart defaults for image, resources, persistence

#### Changes

Create `applications/network-management/unifi-controller/helm-chart/`:

**`Chart.yaml`:**
```yaml
apiVersion: v2
name: unifi-controller
description: UniFi Network Application for managing Ubiquiti access points
type: application
version: 0.1.0
appVersion: "8.6.9"
```

**`values.yaml`** (chart defaults):
```yaml
image:
  repository: jacobalberty/unifi
  tag: v8.6.9
  pullPolicy: IfNotPresent

persistence:
  enabled: true
  storageClass: ""
  size: 10Gi
  accessMode: ReadWriteOnce

resources:
  requests:
    cpu: 100m
    memory: 512Mi
  limits:
    memory: 1Gi

service:
  web:
    type: ClusterIP
    port: 8443
  device:
    type: LoadBalancer
    informPort: 8080
    stunPort: 3478
    discoveryPort: 10001

env:
  TZ: "Europe/Amsterdam"
  UNIFI_STDOUT: "true"
```

**`templates/_helpers.tpl`:**
```yaml
{{- define "unifi-controller.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "unifi-controller.labels" -}}
app.kubernetes.io/name: unifi-controller
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "unifi-controller.selectorLabels" -}}
app.kubernetes.io/name: unifi-controller
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

**`templates/deployment.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "unifi-controller.fullname" . }}
  labels:
    {{- include "unifi-controller.labels" . | nindent 4 }}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "unifi-controller.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "unifi-controller.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: unifi
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: web
              containerPort: 8443
              protocol: TCP
            - name: inform
              containerPort: 8080
              protocol: TCP
            - name: stun
              containerPort: 3478
              protocol: UDP
            - name: discovery
              containerPort: 10001
              protocol: UDP
          env:
            - name: TZ
              value: {{ .Values.env.TZ | quote }}
            - name: UNIFI_STDOUT
              value: {{ .Values.env.UNIFI_STDOUT | quote }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: data
              mountPath: /unifi
          livenessProbe:
            httpGet:
              path: /status
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 120
            periodSeconds: 10
            failureThreshold: 6
          readinessProbe:
            httpGet:
              path: /status
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 60
            periodSeconds: 10
            failureThreshold: 3
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "unifi-controller.fullname" . }}-data
```

**`templates/pvc.yaml`:**
```yaml
{{- if .Values.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "unifi-controller.fullname" . }}-data
  labels:
    {{- include "unifi-controller.labels" . | nindent 4 }}
spec:
  accessModes:
    - {{ .Values.persistence.accessMode }}
  storageClassName: {{ .Values.persistence.storageClass | quote }}
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
{{- end }}
```

**`templates/service-web.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "unifi-controller.fullname" . }}-web
  labels:
    {{- include "unifi-controller.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.web.type }}
  ports:
    - name: https
      port: {{ .Values.service.web.port }}
      targetPort: web
      protocol: TCP
  selector:
    {{- include "unifi-controller.selectorLabels" . | nindent 4 }}
```

**`templates/service-device.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "unifi-controller.fullname" . }}-device
  labels:
    {{- include "unifi-controller.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.device.type }}
  ports:
    - name: inform
      port: {{ .Values.service.device.informPort }}
      targetPort: inform
      protocol: TCP
    - name: stun
      port: {{ .Values.service.device.stunPort }}
      targetPort: stun
      protocol: UDP
    - name: discovery
      port: {{ .Values.service.device.discoveryPort }}
      targetPort: discovery
      protocol: UDP
  selector:
    {{- include "unifi-controller.selectorLabels" . | nindent 4 }}
```

#### Validations

- `helm template ./helm-chart` renders all resources without errors
- Deployment has `strategy: Recreate`
- PVC uses templated storageClass
- Two services created: `-web` (ClusterIP) and `-device` (LoadBalancer)

---

### Phase 2: Helmfile & Deployment

**Goal:** Deploy the controller via ArgoCD

**Scope:**
- Helmfile configuration
- Environment-specific values
- Commit and push to trigger ArgoCD

#### Changes

Create `applications/network-management/unifi-controller/`:

**`helmfile.yaml`:**
```yaml
releases:
  - name: unifi-controller
    namespace: network-management
    chart: ./helm-chart
    values:
      - values.yaml

  - name: unifi-controller-resources
    namespace: network-management
    chart: ./resources
```

**`values.yaml`:**
```yaml
persistence:
  storageClass: truenas-iscsi

resources:
  requests:
    cpu: 100m
    memory: 512Mi
  limits:
    memory: 1Gi
```

#### Validations

- ArgoCD discovers `unifi-controller` application automatically
- Application syncs successfully (Synced, Healthy)
- Pod is Running: `kubectl get pods -n network-management`
- PVC is Bound: `kubectl get pvc -n network-management`
- LoadBalancer has external IP: `kubectl get svc unifi-controller-device -n network-management`

---

### Phase 3: HTTPRoute & Web Access

**Goal:** Expose web UI via gateway

**Scope:**
- Resources chart with HTTPRoute
- Web UI accessible at `unifi.quido.me`

#### Changes

Create `applications/network-management/unifi-controller/resources/`:

**`Chart.yaml`:**
```yaml
apiVersion: v2
name: unifi-controller-resources
description: UniFi Controller additional resources (HTTPRoute)
type: application
version: 0.1.0
```

**`templates/http-route.yaml`:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: unifi-controller
spec:
  parentRefs:
    - name: gateway-internal
      namespace: networking
      group: gateway.networking.k8s.io
      kind: Gateway
  hostnames:
    - unifi.quido.me
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: unifi-controller-web
          port: 8443
          weight: 1
          group: ""
          kind: Service
```

#### Validations

- HTTPRoute is accepted: `kubectl get httproute -n network-management`
- Web UI loads at `https://unifi.quido.me`
- Setup wizard appears (first-time setup)

---

## Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| Local Helm chart | No maintained third-party chart; need control over dual-service pattern |
| Dual services (web + device) | Web UI via HTTPRoute; device ports need direct LoadBalancer for AP communication |
| jacobalberty/unifi image | Well-maintained, bundles MongoDB, commonly used in homelabs |
| Pin image version (v8.6.9) | Stability; avoid unexpected breaking changes |
| Recreate strategy | RWO volume constraint per platform conventions |
| No secrets via Vals | Admin credentials set via web UI; no pre-seeding needed |
| Extended probe delays | Java/MongoDB startup can be slow; avoid premature restarts |

## Non-Goals

- Backup CronJob for controller data (future enhancement)
- Network policies restricting device port access
- Pre-seeded admin credentials or configuration
- High availability / multiple replicas
- External MongoDB deployment

## Validation Plan

### Existing Validations (Must Pass)

None — new realm, no existing deployments affected.

### New Validations

**Phase 1:**
- `helm template ./helm-chart` succeeds
- All expected resources render correctly

**Phase 2:**
- ArgoCD shows application in Synced/Healthy state
- Pod running: `kubectl get pods -n network-management -l app.kubernetes.io/name=unifi-controller`
- PVC bound: `kubectl get pvc -n network-management`
- LoadBalancer IP assigned: `kubectl get svc unifi-controller-device -n network-management -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`

**Phase 3:**
- HTTPRoute accepted: `kubectl get httproute unifi-controller -n network-management -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'` returns `True`
- Web UI accessible: `curl -k https://unifi.quido.me` returns HTML
- Inform endpoint reachable: `curl http://<lb-ip>:8080/inform` returns response (not timeout)

## Implementation Checklist

- [x] Phase 1: Create local Helm chart with Deployment, PVC, Services
- [x] Phase 2: Create Helmfile and values, deploy via ArgoCD
- [x] Phase 3: Add HTTPRoute, verify web UI access
- [ ] Verify all validations pass (after commit/push)
- [ ] Note LoadBalancer IP for AP inform URL configuration
- [ ] Complete initial setup via web UI
- [ ] Adopt access points

## Migration Strategy

Not applicable — this is a new deployment in a new realm. No existing resources are modified.

## Security Considerations

- **TLS**: Gateway terminates TLS for web UI; internal traffic uses controller's self-signed cert on 8443
- **Admin credentials**: Set manually via web UI during initial setup; not stored in Git
- **Network access**: LoadBalancer service accessible from VLAN 40; no network policy restrictions (homelab context)
- **RBAC**: Uses default service account; no elevated permissions required

## Disaster Recovery

- **Git as source of truth**: All manifests in `applications/network-management/unifi-controller/`
- **Data on PVC**: MongoDB data persists on `truenas-iscsi` volume with Retain policy
- **Full recovery**: Delete and re-sync from ArgoCD; PVC data preserved
- **Data loss scenario**: If PVC lost, controller starts fresh; APs require re-adoption
- **Backup**: Manual export via controller UI (Settings > Backup); future enhancement for automated backups
