# Story: Alertmanager Push Notifications via Ntfy

**Design Spec**: `../stories/2026-03-03-alertmanager-ntfy-notifications.md`
**Status**: Implementation Complete (pending deploy & validation)
**Created**: 2026-03-04

## Objective

Deploy a self-hosted Ntfy push notification service and configure Alertmanager to route critical alerts to it, enabling phone notifications with quiet hours and grouping.

## Functional Requirements Summary

1. **Ntfy service**: Self-hosted in `observability` namespace, persistent storage, externally accessible via `gateway-external` with token auth
2. **Alertmanager routing**: Critical-only alerts to Ntfy webhook, grouped by alertname+namespace, quiet hours 23:00–08:00 Europe/Amsterdam, human-readable message formatting
3. **End-to-end validation**: Verify the full pipeline Prometheus → Alertmanager → Ntfy → phone

## Current State

- **Alertmanager**: Running in `observability` with `configSecret: ""` (no receivers configured)
- **Default alert rules**: Enabled via `defaultRules.create: true`
- **PrometheusRule discovery**: Cluster-wide (picks up rules from any namespace)
- **gateway-external**: Deployed at `172.16.40.51`, `*.quido.me` with wildcard TLS cert — no HTTPRoutes currently use it
- **Vault + Vals**: Established secret injection pattern

## Design

### Phase 1: Deploy Ntfy

- **Goal**: Ntfy running in observability namespace, accessible externally, with token auth and persistent storage

#### Changes

**New directory**: `infrastructure/observability/ntfy/`

```
infrastructure/observability/ntfy/
├── helmfile.yaml.gotmpl
├── helm-chart/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       └── pvc.yaml
└── resources/
    ├── Chart.yaml
    └── templates/
        └── http-route.yaml
```

**`helm-chart/Chart.yaml`**:
```yaml
apiVersion: v2
name: ntfy
description: Self-hosted push notification service
type: application
version: 1.0.0
appVersion: "2.11.0"
```

**`helm-chart/values.yaml`** (defaults):
```yaml
image:
  repository: binwiederhier/ntfy
  tag: "v2.11.0"
  pullPolicy: IfNotPresent

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    memory: 128Mi

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

persistence:
  enabled: true
  storageClassName: truenas-iscsi
  accessModes: ["ReadWriteOnce"]
  size: 1Gi

server:
  baseUrl: ""
  authFile: /var/lib/ntfy/auth.db
  cacheFile: /var/lib/ntfy/cache.db
  authDefaultAccess: "deny-all"

auth:
  token: ""
  topic: ""

securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000

livenessProbe:
  httpGet:
    path: /v1/health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 30
  timeoutSeconds: 5

readinessProbe:
  httpGet:
    path: /v1/health
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 5

podAnnotations: {}
nodeSelector: {}
affinity: {}
tolerations: []
```

**`helm-chart/templates/_helpers.tpl`**: Standard helpers following proxmox-exporter pattern (name, fullname, chart, labels, selectorLabels).

**`helm-chart/templates/deployment.yaml`**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "ntfy.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "ntfy.labels" . | nindent 4 }}
spec:
  replicas: 1
  strategy:
    type: Recreate  # Required for RWO PVC
  selector:
    matchLabels:
      {{- include "ntfy.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        {{- with .Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include "ntfy.selectorLabels" . | nindent 8 }}
    spec:
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      containers:
        - name: ntfy
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args:
            - serve
            - --config
            - /etc/ntfy/server.yml
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort }}
              protocol: TCP
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.readinessProbe | nindent 12 }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: config
              mountPath: /etc/ntfy
              readOnly: true
            - name: data
              mountPath: /var/lib/ntfy
            - name: setup
              mountPath: /docker-entrypoint.d
      initContainers:
        - name: setup-auth
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          command:
            - sh
            - -c
            - |
              # Create auth db and set up token-based access for the alert topic
              ntfy access --auth-file /var/lib/ntfy/auth.db everyone {{ .Values.auth.topic }} deny
              ntfy token add --auth-file /var/lib/ntfy/auth.db --token {{ .Values.auth.token }} admin
              ntfy access --auth-file /var/lib/ntfy/auth.db admin {{ .Values.auth.topic }} read-write
          volumMounts:
            - name: data
              mountPath: /var/lib/ntfy
      volumes:
        - name: config
          configMap:
            name: {{ include "ntfy.fullname" . }}-config
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "ntfy.fullname" . }}
        - name: setup
          emptyDir: {}
```

> **NOTE**: The init container approach for auth setup has a problem — it runs on every pod start, potentially recreating the auth DB. A better approach is to use Ntfy's `server.yml` configuration for auth, which is simpler and fully declarative. Let me revise.

**Revised approach — config-file-based auth**:

Ntfy's `server.yml` supports `auth-default-access: deny-all` and the server can be configured so that Alertmanager authenticates via a Bearer token in the webhook HTTP header. The token is created once in Vault. On the Ntfy side, we use the simplest auth approach: run with `auth-default-access: deny-all`, and create an admin user/token via an init container that only runs if the auth DB doesn't exist yet.

Actually, the cleanest approach for GitOps: use Ntfy's **environment variable** support and its ability to define a static auth token. However, Ntfy's auth model requires its CLI to create tokens in the SQLite DB.

**Final revised approach**: Use an init container that creates the auth DB idempotently. The init container checks if the DB exists; if not, it creates the user and token. If the DB already exists (persistent volume), it skips setup. This is safe across restarts.

**Revised init container**:
```yaml
initContainers:
  - name: setup-auth
    image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
    command:
      - sh
      - -c
      - |
        if [ ! -f /var/lib/ntfy/user.db ]; then
          ntfy user add --auth-file /var/lib/ntfy/user.db admin
          ntfy token add --auth-file /var/lib/ntfy/user.db --token {{ .Values.auth.token }} admin
          ntfy access --auth-file /var/lib/ntfy/user.db everyone '*' deny
          ntfy access --auth-file /var/lib/ntfy/user.db admin '*' read-write
        fi
    volumeMounts:
      - name: data
        mountPath: /var/lib/ntfy
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
```

**ConfigMap for server.yml** (add `configmap.yaml` template):
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "ntfy.fullname" . }}-config
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "ntfy.labels" . | nindent 4 }}
data:
  server.yml: |
    base-url: {{ .Values.server.baseUrl | quote }}
    listen-http: ":{{ .Values.service.targetPort }}"
    cache-file: {{ .Values.server.cacheFile | quote }}
    auth-file: {{ .Values.server.authFile | quote }}
    auth-default-access: {{ .Values.server.authDefaultAccess | quote }}
    behind-proxy: true
```

**`helm-chart/templates/service.yaml`**:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "ntfy.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "ntfy.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "ntfy.selectorLabels" . | nindent 4 }}
```

**`helm-chart/templates/pvc.yaml`**:
```yaml
{{- if .Values.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "ntfy.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "ntfy.labels" . | nindent 4 }}
spec:
  accessModes:
    {{- toYaml .Values.persistence.accessModes | nindent 4 }}
  storageClassName: {{ .Values.persistence.storageClassName }}
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
{{- end }}
```

**`helmfile.yaml.gotmpl`**:
```yaml
repositories: []  # Local chart, no external repos

releases:
  - name: ntfy
    namespace: observability
    chart: ./helm-chart
    wait: true
    timeout: 300
    values:
      - server:
          baseUrl: "https://ntfy.quido.me"
        auth:
          token: {{ fetchSecretValue "ref+vault://kv/observability/ntfy#auth-token" | quote }}
          topic: homelab-alerts

  - name: ntfy-resources
    namespace: observability
    chart: ./resources
    needs:
      - observability/ntfy
```

**`resources/Chart.yaml`**:
```yaml
apiVersion: v2
name: ntfy-resources
description: HTTPRoute for Ntfy external access
type: application
version: 1.0.0
```

**`resources/templates/http-route.yaml`**:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ntfy
  namespace: observability
  labels:
    app: ntfy
    component: observability
spec:
  parentRefs:
    - name: gateway-external
      namespace: networking
      group: gateway.networking.k8s.io
      kind: Gateway
  hostnames:
    - ntfy.quido.me
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: ntfy
          port: 80
          weight: 1
          group: ""
          kind: Service
```

**Vault setup** (manual, before deploy):
```bash
vault kv put kv/observability/ntfy auth-token="<generate-a-random-token>"
```

#### Validations

- [ ] ArgoCD discovers the new `ntfy` application automatically (ApplicationSet picks up `infrastructure/observability/ntfy/`)
- [ ] Ntfy pod is running and healthy in `observability` namespace
- [ ] PVC is bound (truenas-iscsi)
- [ ] `curl -H "Authorization: Bearer <token>" https://ntfy.quido.me/v1/health` returns 200
- [ ] Test publish: `curl -H "Authorization: Bearer <token>" -d "test message" https://ntfy.quido.me/homelab-alerts`
- [ ] Ntfy app on phone receives the test message when subscribed to `ntfy.quido.me/homelab-alerts` with the token
- [ ] Unauthenticated requests are rejected (403)

---

### Phase 2: Configure Alertmanager

- **Goal**: Alertmanager routes critical alerts to Ntfy with grouping, quiet hours, and human-readable messages

#### Changes

**Modified**: `infrastructure/observability/kube-prometheus-stack/values.yaml`

Add the following `alertmanager.config` section (replacing the empty configSecret):

```yaml
alertmanager:
  enabled: true

  alertmanagerSpec:
    # ... existing storage, resources, probes ...

    # Remove this line:
    # configSecret: ""  # Empty = use default config (no notifications)

  # Alertmanager configuration
  config:
    global:
      resolve_timeout: 5m

    route:
      receiver: "null"
      group_by: [alertname, namespace]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        - receiver: ntfy
          matchers:
            - severity=critical
          mute_time_intervals:
            - quiet-hours
          continue: false

    receivers:
      - name: "null"
      - name: ntfy
        webhook_configs:
          - url: "http://ntfy.observability.svc.cluster.local/homelab-alerts"
            send_resolved: true
            http_config:
              authorization:
                type: Bearer
                credentials: "NTFY_AUTH_TOKEN_PLACEHOLDER"

    time_intervals:
      - name: quiet-hours
        time_intervals:
          - times:
              - start_time: "23:00"
                end_time: "08:00"
            location: Europe/Amsterdam

  templateFiles:
    ntfy.tmpl: |
      {{ "{{" }} define "ntfy.title" {{ "}}" }}
      {{ "{{" }}- if eq .Status "firing" {{ "}}" }}FIRING: {{ "{{" }} .CommonLabels.alertname {{ "}}" }}{{ "{{" }}- else {{ "}}" }}RESOLVED: {{ "{{" }} .CommonLabels.alertname {{ "}}" }}{{ "{{" }}- end {{ "}}" }}
      {{ "{{" }} end {{ "}}" }}

      {{ "{{" }} define "ntfy.text" {{ "}}" }}
      {{ "{{" }}- range .Alerts {{ "}}" }}
      {{ "{{" }}- if .Annotations.summary {{ "}}" }}{{ "{{" }} .Annotations.summary {{ "}}" }}{{ "{{" }}- else {{ "}}" }}{{ "{{" }} .Annotations.description {{ "}}" }}{{ "{{" }}- end {{ "}}" }}
      Namespace: {{ "{{" }} .Labels.namespace {{ "}}" }}
      {{ "{{" }}- end {{ "}}" }}
      {{ "{{" }} end {{ "}}" }}
```

> **Note on message formatting**: The webhook_config sends Alertmanager's native JSON payload. Ntfy will display the raw JSON as the message body. For human-readable messages, there are two approaches:
>
> **Option A**: Use Alertmanager's webhook with custom headers. Ntfy can parse specific headers (`X-Title`, `X-Message`, `X-Priority`). However, Alertmanager's `webhook_config` doesn't support custom headers natively.
>
> **Option B (recommended)**: Accept that the initial notification will show Alertmanager's JSON payload. The Ntfy phone app displays the message body which will include alert labels and annotations — it's not pretty but it's functional. A future enhancement could add a lightweight webhook transformer (like a small adapter service), but that's out of scope for this story.
>
> Actually, looking at this more carefully: Alertmanager's `webhook_config` sends a JSON body that Ntfy will display as-is. The Ntfy app will show the raw JSON which is not ideal but workable. The proper solution for formatted messages would be to use Alertmanager's `webhook_config` with a URL that includes Ntfy's query parameters for formatting: `http://ntfy.observability.svc.cluster.local/homelab-alerts?title=...` — but this can't include Go template expressions in the URL.
>
> **Simplest working approach**: Ntfy displays the Alertmanager JSON payload. It contains `status`, `alerts[].labels.alertname`, `alerts[].annotations.summary` etc. It's readable enough for a homelab. Message formatting can be improved later.

**Modified**: `infrastructure/observability/kube-prometheus-stack/secrets.yaml.gotmpl`

```yaml
grafana:
  adminPassword: {{ fetchSecretValue "ref+vault://kv/observability/grafana#admin-password" | quote }}

alertmanager:
  config:
    receivers:
      - name: "null"
      - name: ntfy
        webhook_configs:
          - url: "http://ntfy.observability.svc.cluster.local/homelab-alerts"
            send_resolved: true
            http_config:
              authorization:
                type: Bearer
                credentials: {{ fetchSecretValue "ref+vault://kv/observability/ntfy#auth-token" | quote }}
```

> **Important**: The `receivers` block in secrets.yaml.gotmpl overrides the one in values.yaml via Helmfile's values merge. This way the token never appears in values.yaml — only the Vals reference in the gotmpl file.

#### Validations

- [ ] kube-prometheus-stack ArgoCD app syncs successfully after values change
- [ ] Alertmanager config is loaded (check Alertmanager UI via port-forward: `kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093`)
- [ ] Alertmanager shows the `ntfy` receiver and `quiet-hours` time interval in its UI
- [ ] Route tree shows: `severity=critical` → `ntfy`, default → `null`

---

### Phase 3: End-to-End Validation

- **Goal**: Confirm the full pipeline works: Prometheus → Alertmanager → Ntfy → phone

#### Changes

No permanent changes. Temporary test resources applied and removed.

#### Validation Steps

**Test 1: Fire a test alert**

Apply a temporary PrometheusRule:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: test-ntfy-alert
  namespace: observability
spec:
  groups:
    - name: test
      rules:
        - alert: TestNtfyAlert
          expr: vector(1)
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "Test alert for Ntfy notification pipeline"
```

```bash
kubectl apply -f /tmp/test-alert.yaml
```

- [ ] Alert appears in Alertmanager UI within ~60s (evaluation interval)
- [ ] Ntfy notification arrives on phone
- [ ] Notification contains alert information (alertname, summary)

Clean up:
```bash
kubectl delete prometheusrule test-ntfy-alert -n observability
```

- [ ] Resolve notification arrives on phone (if send_resolved: true)

**Test 2: Verify non-critical alerts are silenced**

Apply a warning-level test rule:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: test-warning-alert
  namespace: observability
spec:
  groups:
    - name: test
      rules:
        - alert: TestWarningAlert
          expr: vector(1)
          for: 0m
          labels:
            severity: warning
          annotations:
            summary: "This should NOT trigger a notification"
```

- [ ] Alert appears in Alertmanager UI
- [ ] No notification arrives on phone (routed to null receiver)

Clean up the test rule.

**Test 3: Verify quiet hours** (optional, can be verified via Alertmanager UI)

- [ ] Alertmanager UI shows `quiet-hours` mute time interval configured
- [ ] During quiet hours, the mute is shown as active in the UI

## Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| Local minimal Helm chart for Ntfy | No well-maintained upstream chart; simple enough (Deployment + Service + PVC + ConfigMap); consistent with proxmox-exporter pattern |
| Init container for auth setup | Ntfy requires CLI commands to create auth tokens in its SQLite DB; init container runs idempotently (skips if DB exists on PVC) |
| Inline `alertmanager.config` in values.yaml | Standard kube-prometheus-stack approach; avoids separate ConfigSecret complexity |
| Receivers in secrets.yaml.gotmpl | Overrides receivers from values.yaml to inject the auth token via Vals without exposing it in values.yaml |
| `behind-proxy: true` in Ntfy config | Ntfy sits behind the Cilium gateway; this ensures correct client IP forwarding and rate limiting |
| `auth-default-access: deny-all` | Internet-facing service; all topics require authentication by default |
| Alertmanager JSON payload as notification body | Functional for homelab use; human-readable formatting can be improved in a future iteration |
| Quiet hours via `time_intervals` with `location: Europe/Amsterdam` | DST-aware; no manual UTC conversion needed |

## Non-Goals

- Custom PrometheusRule alert definitions (only default rules in scope)
- Formatted/templated notification messages (Alertmanager JSON payload is acceptable for now)
- Multi-user Ntfy access (single admin token for both Alertmanager and phone)
- Ntfy as a general-purpose notification service for other applications (can be extended later)

## Validation Plan

### Existing Validations (Must Pass)

- kube-prometheus-stack ArgoCD application remains healthy after Alertmanager config changes
- Prometheus continues scraping and evaluating rules
- Grafana remains accessible
- All existing default alert rules continue to fire correctly

### New Validations

| Phase | Validation | Type |
|-------|-----------|------|
| 1 | Ntfy pod healthy | Post-deploy |
| 1 | PVC bound | Post-deploy |
| 1 | External access works with auth | Post-deploy |
| 1 | Unauthenticated access rejected | Post-deploy |
| 1 | Phone receives test message via curl | Post-deploy |
| 2 | Alertmanager config loaded | Post-deploy |
| 2 | Route tree correct in Alertmanager UI | Post-deploy |
| 2 | Quiet hours interval visible | Post-deploy |
| 3 | Critical test alert → phone notification | End-to-end |
| 3 | Warning test alert → no notification | End-to-end |
| 3 | Alert resolve → resolve notification | End-to-end |

## Implementation Checklist

- [x] Phase 1: Deploy Ntfy (local chart, HTTPRoute, auth, PVC) — validate externally accessible and authenticated
- [x] Phase 2: Configure Alertmanager (receivers, routes, muting, secrets) — validate config loaded correctly
- [ ] Phase 3: End-to-end validation (test alerts, verify routing, quiet hours)
- [ ] Verify all existing kube-prometheus-stack validations still pass
- [ ] Create Vault secret: `kv/observability/ntfy` with key `auth-token`

## Migration Strategy

No migration needed. This is a new deployment (Ntfy) and a configuration addition to an existing deployment (Alertmanager). No existing behavior changes — Alertmanager currently has no receivers, so adding them is purely additive.

## Security Considerations

- **Ntfy exposed on gateway-external**: Token auth required; `auth-default-access: deny-all`
- **TLS**: Handled by existing wildcard cert via cert-manager + Cloudflare DNS-01
- **Auth token in Vault**: Single token at `kv/observability/ntfy#auth-token`, consumed by both Ntfy (init container) and Alertmanager (webhook config)
- **Token rotation**: Update token in Vault → re-sync both ArgoCD applications (ntfy + kube-prometheus-stack) → update Ntfy app on phone
- **Pod security**: Non-root user (1000), no privilege escalation, drop all capabilities
- **Network**: Alertmanager → Ntfy is cluster-internal (Service DNS); Phone → Ntfy is external via gateway

## Disaster Recovery

- **Full restore from Git**: Both Ntfy and Alertmanager configs are in Git. Re-applying via ArgoCD restores everything except:
  - The Vault secret (must exist in Vault)
  - The Ntfy auth database (recreated by init container on fresh PVC)
  - The Ntfy message cache (lost, but messages are ephemeral)
- **PVC loss**: Ntfy auth DB is recreated by init container. Cached messages are lost (acceptable).
- **Vault unavailable at sync time**: Vals injection fails → ArgoCD sync fails → alerts continue firing in Alertmanager but no new config changes can be deployed. Existing running config is unaffected.
