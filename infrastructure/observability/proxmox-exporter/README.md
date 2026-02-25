# Proxmox Exporter

Prometheus exporter for Proxmox VE host monitoring.

## Architecture

- **Exporter**: prompve/prometheus-pve-exporter:3.8.1
- **Deployment**: Single replica (sufficient for one Proxmox host)
- **Metrics port**: 9221
- **Scrape path**: /pve?target=<host>
- **Authentication**: Proxmox API token (stored in Vault)

## Vault Secrets

**Path**: `kv/observability/proxmox-exporter`

**Required keys**:
- `PROXMOX_USER`: Username (e.g., "monitoring@pve")
- `PROXMOX_TOKEN_NAME`: Token name (e.g., "prometheus")
- `PROXMOX_TOKEN_VALUE`: UUID token value

## Deployment

Deployed via Helmfile and ArgoCD:
1. Credentials stored in Vault (split into user, token name, and token value)
2. Git commit triggers ArgoCD sync
3. Vals injects secrets at deploy-time
4. Pod deployed in `observability` namespace
5. ServiceMonitor configures Prometheus scraping with target parameter

## Credential Rotation

When Proxmox credentials change:

1. Generate new token in Proxmox UI or CLI:
   ```bash
   pveum user token add monitoring@pve prometheus --privsep 0
   ```

2. Update Vault secret:
   ```bash
   vault kv put kv/observability/proxmox-exporter \
     PROXMOX_USER="monitoring@pve" \
     PROXMOX_TOKEN_NAME="prometheus" \
     PROXMOX_TOKEN_VALUE="<new-token-uuid>"
   ```

3. Trigger ArgoCD sync:
   ```bash
   argocd app sync observability-proxmox-exporter
   ```

4. Deployment rolls out with new credentials

## Troubleshooting

### Pod not ready / CrashLoopBackOff

Check logs:
```bash
kubectl logs -n observability -l app.kubernetes.io/name=proxmox-exporter
```

Common causes:
- **Invalid credentials**: 401 errors in logs — verify Vault secrets are correct and token exists in Proxmox
- **Proxmox host unreachable**: Connection timeout — verify network connectivity and DNS resolution
- **Vault secrets missing**: Vals error during sync — ensure all three keys exist in Vault
- **readOnlyRootFilesystem issue**: Temp directory errors — ensure emptyDir volume mounted at /tmp

### Prometheus target down

Verify pod is ready:
```bash
kubectl get pods -n observability -l app.kubernetes.io/name=proxmox-exporter
```

Check metrics endpoint:
```bash
kubectl exec -n observability deployment/proxmox-exporter -- \
  wget -q -O- "http://localhost:9221/pve?target=pve2.lan.balti.casa" | head -20
```

Verify ServiceMonitor exists:
```bash
kubectl get servicemonitor -n observability proxmox-exporter -o yaml
```

Check Prometheus targets:
```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# Navigate to http://localhost:9090/targets and search for "proxmox"
```

### Dashboard shows "No data"

1. Wait 60s (one scrape interval)
2. Verify Prometheus target is UP
3. Check metrics exist in Prometheus:
   ```bash
   kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
     wget -q -O- 'http://localhost:9090/api/v1/query?query=up{job="proxmox-exporter"}'
   ```
4. Manually import dashboard from Grafana.com:
   - Go to Grafana > Dashboards > New > Import
   - Enter dashboard ID: 10347
   - Select Prometheus datasource
   - Import

### Authentication errors (401 Unauthorized)

The exporter expects separate user and token name:
- `PVE_USER`: Just the username part (e.g., "monitoring@pve")
- `PVE_TOKEN_NAME`: Just the token name part (e.g., "prometheus")
- `PVE_TOKEN_VALUE`: The UUID token value

If you see `no such user ('user!token!user')` errors, the values are incorrectly formatted.

## Validation

Run automated validation:
```bash
./validate.sh
```

Manual verification:
```bash
# Check pod is running
kubectl get pods -n observability -l app.kubernetes.io/name=proxmox-exporter

# Check Prometheus is scraping
kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/query?query=pve_up'

# List Proxmox metrics
kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/label/__name__/values' | grep pve_
```
