# Vault Monitoring

Prometheus monitoring for HashiCorp Vault with alerts and Grafana dashboards.

## Architecture

- **Target**: Vault in `security` namespace
- **Metrics endpoint**: `/v1/sys/metrics?format=prometheus`
- **Scrape interval**: 15s
- **Cross-namespace**: ServiceMonitor in `observability` scrapes Vault in `security`

## Components

| Resource | Purpose |
|----------|---------|
| ServiceMonitor | Configures Prometheus to scrape Vault metrics |
| PrometheusRule | Defines 4 alerting rules |
| ConfigMap (x2) | Grafana dashboard definitions |

## Alerts

| Alert | Severity | Description |
|-------|----------|-------------|
| VaultSealed | critical | Vault is sealed, manual unseal required |
| VaultHighMemory | warning | Memory usage above 90% of limit |
| ExternalSecretSyncFailure | warning | ExternalSecret failing to sync (Vault connectivity issue) |
| VaultTokenExpiringSoon | warning | vals-reader token expiring within 7 days |

## Configuration

### Token Expiration Alert

The `VaultTokenExpiringSoon` alert uses time-based calculation. Update `valsTokenCreatedAt` in `helmfile.yaml` when rotating the vals-reader token:

```yaml
alerts:
  tokenExpiration:
    valsTokenCreatedAt: "2026-03-01"  # Update with actual date
    warningDays: 7
```

## Deployment

Deployed via Helmfile and ArgoCD:
1. Git commit triggers ArgoCD sync
2. Helm chart deployed to `observability` namespace
3. Prometheus discovers ServiceMonitor and starts scraping
4. Alert rules loaded into Prometheus
5. Grafana sidecar imports dashboards from ConfigMaps

## Vault Telemetry Requirement

Vault must have telemetry enabled. This is configured in `infrastructure/security/vault/values.yaml`:

```hcl
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname = false
}

listener "tcp" {
  # ...
  telemetry {
    unauthenticated_metrics_access = true
  }
}
```

**Note**: `unauthenticated_metrics_access` moved to the listener block in Vault 1.18+.

## Troubleshooting

### Vault metrics endpoint returns 403

1. Check Vault is unsealed:
   ```bash
   kubectl exec -n security vault-0 -- vault status
   ```

2. Verify telemetry config applied:
   ```bash
   kubectl exec -n security vault-0 -- cat /vault/config/extraconfig-from-values.hcl | grep -A3 telemetry
   ```

3. If config missing, restart Vault pod:
   ```bash
   kubectl delete pod vault-0 -n security
   # Then unseal with 3 keys
   ```

### Prometheus target not found

Wait 30-60 seconds for discovery, then check:
```bash
kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/targets' | jq '.data.activeTargets[] | select(.labels.job=="vault-monitoring")'
```

### Alert not firing when expected

Verify alert rules loaded:
```bash
kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/rules' | jq '.data.groups[] | select(.name | startswith("vault-"))'
```

### Dashboards not appearing in Grafana

1. Check Grafana sidecar enabled:
   ```bash
   kubectl get deployment kube-prometheus-stack-grafana -n observability -o jsonpath='{.spec.template.spec.containers[*].name}'
   # Should include "grafana-sc-dashboard"
   ```

2. Check ConfigMaps have correct label:
   ```bash
   kubectl get configmap -n observability -l grafana_dashboard=1 | grep vault-monitoring
   ```

3. Restart Grafana to force sidecar rescan:
   ```bash
   kubectl rollout restart deployment/kube-prometheus-stack-grafana -n observability
   ```

## Validation

Run automated validation:
```bash
./validate.sh
```

Manual verification:
```bash
# Check Vault metrics endpoint
kubectl exec -n security vault-0 -- \
  wget -q -O- "http://localhost:8200/v1/sys/metrics?format=prometheus" | grep vault_core_unsealed

# Check Prometheus is scraping
kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/query?query=vault_core_unsealed'

# List vault metrics in Prometheus
kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/label/__name__/values' | jq '.data[]' | grep vault_
```

## Unsealing Vault

After any Vault pod restart, unseal is required:
```bash
kubectl exec -n security vault-0 -- vault operator unseal <key1>
kubectl exec -n security vault-0 -- vault operator unseal <key2>
kubectl exec -n security vault-0 -- vault operator unseal <key3>
```

See `infrastructure/security/vault/README.md` for full unseal procedures.
