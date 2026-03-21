#!/usr/bin/env bash
# Vault Monitoring Deployment Validation
# Based on proxmox-exporter/validate.sh pattern

set -e

echo "=== Vault Monitoring Validation ==="
echo ""

PASS=0
FAIL=0
WARN=0

check_pass() {
  echo "   [PASS] $1"
  PASS=$((PASS + 1))
}

check_fail() {
  echo "   [FAIL] $1"
  FAIL=$((FAIL + 1))
}

check_warn() {
  echo "   [WARN] $1"
  WARN=$((WARN + 1))
}

# 1. Check prerequisites (namespaces exist)
echo "1. Checking prerequisites..."
if kubectl get namespace observability >/dev/null 2>&1 && kubectl get namespace security >/dev/null 2>&1; then
  check_pass "observability and security namespaces exist"
else
  check_fail "Required namespaces missing"
fi

# 2. Check ArgoCD application (using kubectl, not argocd CLI)
echo "2. Checking ArgoCD application..."
APP_STATUS=$(kubectl get application vault-monitoring -n gitops -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NotFound")
APP_HEALTH=$(kubectl get application vault-monitoring -n gitops -o jsonpath='{.status.health.status}' 2>/dev/null || echo "NotFound")

if [ "$APP_STATUS" = "Synced" ] && [ "$APP_HEALTH" = "Healthy" ]; then
  check_pass "ArgoCD application Synced and Healthy"
elif [ "$APP_STATUS" = "NotFound" ]; then
  check_fail "ArgoCD application not found (not deployed yet?)"
else
  check_fail "ArgoCD application status: Sync=$APP_STATUS, Health=$APP_HEALTH"
fi

# 3. Check Vault running and unsealed
echo "3. Checking Vault status..."
VAULT_SEALED=$(kubectl exec -n security vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "error")
if [ "$VAULT_SEALED" = "false" ]; then
  check_pass "Vault running and unsealed"
elif [ "$VAULT_SEALED" = "true" ]; then
  check_fail "Vault is SEALED - unseal required"
else
  check_fail "Cannot check Vault status"
fi

# 4. Check Vault telemetry configuration
echo "4. Checking Vault telemetry configuration..."
TELEMETRY_CONFIG=$(kubectl get statefulset vault -n security -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)
if echo "$TELEMETRY_CONFIG" | grep -q "prometheus_retention_time" 2>/dev/null; then
  check_pass "Vault telemetry configuration present"
else
  # Check configmap or config file
  CONFIG_DATA=$(kubectl exec -n security vault-0 -- cat /vault/config/extraconfig-from-values.hcl 2>/dev/null || echo "")
  if echo "$CONFIG_DATA" | grep -q "telemetry" 2>/dev/null; then
    check_pass "Vault telemetry configuration present (in config file)"
  else
    check_fail "Vault telemetry not configured"
  fi
fi

# 5. Check ServiceMonitor exists
echo "5. Checking ServiceMonitor..."
if kubectl get servicemonitor vault-monitoring -n observability >/dev/null 2>&1; then
  check_pass "ServiceMonitor exists"
else
  check_fail "ServiceMonitor not found"
fi

# 6. Check ServiceMonitor targets security namespace
echo "6. Checking ServiceMonitor namespace selector..."
SM_NS=$(kubectl get servicemonitor vault-monitoring -n observability -o jsonpath='{.spec.namespaceSelector.matchNames[0]}' 2>/dev/null || echo "")
if [ "$SM_NS" = "security" ]; then
  check_pass "ServiceMonitor targets security namespace"
else
  check_fail "ServiceMonitor namespace selector incorrect: $SM_NS"
fi

# 7. Check Vault metrics endpoint
echo "7. Checking Vault metrics endpoint..."
METRICS_RESPONSE=$(kubectl exec -n security vault-0 -- wget -q -O- "http://localhost:8200/v1/sys/metrics?format=prometheus" 2>/dev/null | head -5 || echo "")
if echo "$METRICS_RESPONSE" | grep -q "vault_" 2>/dev/null; then
  check_pass "Vault metrics endpoint responding"
else
  check_fail "Vault metrics endpoint not available (telemetry not enabled?)"
fi

# 8. Check Prometheus target
echo "8. Checking Prometheus target..."
TARGET_HEALTH=$(kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/targets' 2>/dev/null | \
  jq -r '.data.activeTargets[] | select(.labels.job=="vault-monitoring") | .health' | head -1)

if [ "$TARGET_HEALTH" = "up" ]; then
  check_pass "Prometheus target UP"
elif [ -z "$TARGET_HEALTH" ]; then
  check_warn "Prometheus target not found (may need time to discover)"
else
  check_fail "Prometheus target status: $TARGET_HEALTH"
fi

# 9. Check Vault metrics queryable
echo "9. Checking Vault metrics in Prometheus..."
METRIC_VALUE=$(kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/query?query=vault_core_unsealed' 2>/dev/null | \
  jq -r '.data.result[0].value[1]' 2>/dev/null || echo "")

if [ "$METRIC_VALUE" = "1" ]; then
  check_pass "Vault metrics queryable (vault_core_unsealed=1)"
elif [ -z "$METRIC_VALUE" ]; then
  check_warn "vault_core_unsealed metric not found (may need time)"
else
  check_fail "vault_core_unsealed unexpected value: $METRIC_VALUE"
fi

# 10. Check PrometheusRule exists with alerts
echo "10. Checking PrometheusRule..."
ALERT_COUNT=$(kubectl get prometheusrule vault-monitoring -n observability -o jsonpath='{.spec.groups[*].rules[*].alert}' 2>/dev/null | wc -w || echo "0")
if [ "$ALERT_COUNT" -ge 4 ]; then
  check_pass "PrometheusRule exists with $ALERT_COUNT alerts"
elif [ "$ALERT_COUNT" -gt 0 ]; then
  check_warn "PrometheusRule has only $ALERT_COUNT alerts (expected 4)"
else
  check_fail "PrometheusRule not found or has no alerts"
fi

# 11. Check alert rules loaded in Prometheus
echo "11. Checking alert rules in Prometheus..."
RULE_GROUPS=$(kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/rules' 2>/dev/null | \
  jq -r '.data.groups[].name' | grep -c "vault-" || echo "0")

if [ "$RULE_GROUPS" -ge 2 ]; then
  check_pass "Alert rules loaded (vault-health and vault-downstream-impact groups)"
elif [ "$RULE_GROUPS" -gt 0 ]; then
  check_warn "Only $RULE_GROUPS vault rule groups found"
else
  check_fail "No vault alert rule groups in Prometheus"
fi

# 12. Check dashboard ConfigMaps
echo "12. Checking dashboard ConfigMaps..."
DASHBOARD_CMS=$(kubectl get configmap -n observability -l grafana_dashboard=1 --no-headers 2>/dev/null | grep -c "vault-monitoring" || echo "0")
if [ "$DASHBOARD_CMS" -ge 2 ]; then
  check_pass "Dashboard ConfigMaps exist ($DASHBOARD_CMS found)"
elif [ "$DASHBOARD_CMS" -gt 0 ]; then
  check_warn "Only $DASHBOARD_CMS dashboard ConfigMaps found (expected 2)"
else
  check_fail "No dashboard ConfigMaps found"
fi

# 13. Check Grafana sidecar enabled
echo "13. Checking Grafana sidecar..."
SIDECAR_CONTAINERS=$(kubectl get deployment kube-prometheus-stack-grafana -n observability -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null | grep -c "sc-dashboard" || echo "0")
if [ "$SIDECAR_CONTAINERS" -gt 0 ]; then
  check_pass "Grafana dashboard sidecar enabled"
else
  check_warn "Grafana sidecar not detected - manual dashboard import required"
fi

# 14. Check kube-state-metrics ExternalSecret support
echo "14. Checking kube-state-metrics ExternalSecret metrics..."
ES_METRICS=$(kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/query?query=kube_externalsecret_info' 2>/dev/null | \
  jq -r '.data.result | length' 2>/dev/null || echo "0")

ES_COUNT=$(kubectl get externalsecret -A --no-headers 2>/dev/null | wc -l)
if [ "$ES_METRICS" -gt 0 ]; then
  check_pass "kube-state-metrics exposes ExternalSecret metrics"
elif [ "$ES_COUNT" -eq 0 ]; then
  check_warn "No ExternalSecrets in cluster - cannot verify metrics exposure"
else
  check_warn "kube-state-metrics may not expose ExternalSecret CRD metrics"
fi

# 15. Check token creation date configured
echo "15. Checking token creation date configuration..."
TOKEN_DATE=$(kubectl get prometheusrule vault-monitoring -n observability -o yaml 2>/dev/null | grep -o 'valsTokenCreatedAt.*' | head -1 || echo "")
if [ -n "$TOKEN_DATE" ] && ! echo "$TOKEN_DATE" | grep -q "2026-03-01"; then
  check_pass "Token creation date configured (not default)"
elif echo "$TOKEN_DATE" | grep -q "2026-03-01"; then
  check_warn "Token creation date is default value - update with actual date"
else
  check_warn "Cannot verify token creation date configuration"
fi

echo ""
echo "=== Validation Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Warnings: $WARN"
echo ""

if [ $FAIL -gt 0 ]; then
  echo "Some checks failed. Review output above."
  exit 1
fi

echo "All critical checks passed!"
echo ""
echo "Manual verification steps:"
echo "  1. Verify alerts in Prometheus UI:"
echo "     kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090"
echo "     Navigate to http://localhost:9090/alerts"
echo "  2. Verify dashboards in Grafana UI:"
echo "     kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80"
echo "     Navigate to http://localhost:3000 -> Dashboards -> Infrastructure"
echo "  3. Test VaultSealed alert (see spec Phase 4)"
echo "  4. Verify notifications delivered"
