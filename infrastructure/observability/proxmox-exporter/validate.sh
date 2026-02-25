#!/bin/bash
# Proxmox Exporter Deployment Validation

set -e

echo "=== Proxmox Exporter Validation ==="
echo ""

# 1. Check ArgoCD application
echo "1. Checking ArgoCD application..."
if argocd app get observability-proxmox-exporter --refresh >/dev/null 2>&1; then
  SYNC_STATUS=$(argocd app get observability-proxmox-exporter -o json | jq -r '.status.sync.status')
  HEALTH_STATUS=$(argocd app get observability-proxmox-exporter -o json | jq -r '.status.health.status')
  if [ "$SYNC_STATUS" = "Synced" ] && [ "$HEALTH_STATUS" = "Healthy" ]; then
    echo "   ✓ Application synced and healthy"
  else
    echo "   ✗ Application status: Sync=$SYNC_STATUS, Health=$HEALTH_STATUS"
    exit 1
  fi
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
if kubectl exec -n observability deployment/proxmox-exporter -- \
  wget -q -O- "http://localhost:9221/pve?target=pve2.lan.balti.casa" 2>/dev/null | grep -q "pve_up"; then
  echo "   ✓ Metrics exposed"
else
  echo "   ✗ Metrics not available"
  exit 1
fi

# 5. Check Prometheus target
echo "5. Checking Prometheus target..."
TARGET_HEALTH=$(kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/targets' 2>/dev/null | \
  jq -r '.data.activeTargets[] | select(.labels.job=="proxmox-exporter") | .health')

if [ "$TARGET_HEALTH" = "up" ]; then
  echo "   ✓ Prometheus target UP"
else
  echo "   ✗ Prometheus target status: $TARGET_HEALTH"
  exit 1
fi

# 6. Check metrics in Prometheus
echo "6. Checking metrics in Prometheus..."
METRIC_VALUE=$(kubectl exec -n observability statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/query?query=up{job="proxmox-exporter"}' 2>/dev/null | \
  jq -r '.data.result[0].value[1]' 2>/dev/null)

if [ "$METRIC_VALUE" = "1" ]; then
  echo "   ✓ Metrics queryable (up=1)"
else
  echo "   ✗ Metrics not queryable or target down"
  exit 1
fi

# 7. Check dashboard ConfigMap
echo "7. Checking dashboard ConfigMap..."
if kubectl get configmap -n observability -l grafana_dashboard=1 2>/dev/null | grep -q proxmox-exporter; then
  echo "   ✓ Dashboard ConfigMap exists"
else
  echo "   ✗ Dashboard ConfigMap not found"
  exit 1
fi

echo ""
echo "=== Validation Complete ==="
echo ""
echo "All automated checks passed!"
echo ""
echo "Manual steps (if needed):"
echo "  - Import dashboard in Grafana UI:"
echo "    1. kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80"
echo "    2. Navigate to http://localhost:3000"
echo "    3. Go to Dashboards > New > Import"
echo "    4. Enter dashboard ID: 10347"
echo "    5. Select Prometheus datasource and import"
