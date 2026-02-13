# Vault + Vals Test Examples

This directory contains test files for validating Vault + Vals integration.

## Files

- `test-vals.yaml.gotmpl` - Test helmfile with Vals secret references
- `argocd-test-app.yaml` - ArgoCD Application for testing
- `README.md` - This file

## Test 1: Local Development

### Prerequisites
- Vault unsealed
- vals-reader token created (see `../VALS-SETUP.md`)
- Port-forward to Vault

### Run the Test

```bash
# Set your vals-reader token
export VALS_TOKEN="<your-vals-reader-token>"

# Run test script
./scripts/test-vals-local.sh
```

### Expected Output

The helmfile template should show a ConfigMap with actual secret values:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vals-test-result
data:
  foo: "bar"
  message: "Hello from Vault"
  number: "42"
  test-passed: "true"
```

### Troubleshooting

**Problem:** Output shows `ref+vault://...` literally

**Solution:** Check environment variables:
```bash
echo $VAULT_ADDR
echo $VAULT_TOKEN
```

Both should be set. Re-run the script.

**Problem:** "permission denied" error

**Solution:** Token doesn't have read access. Verify:
```bash
kubectl exec -n security vault-0 -- sh -c "
export VAULT_TOKEN=<root-token>
vault token lookup $VALS_TOKEN
"
```

Should show `vals-reader` policy.

---

## Test 2: ArgoCD Integration

### Prerequisites
- ArgoCD repo-server configured with VAULT_ADDR and VAULT_TOKEN (see `../VALS-SETUP.md`)
- Test changes committed and pushed to git

### Run the Test

```bash
# Apply the test application
kubectl apply -f infrastructure/security/vault/examples/argocd-test-app.yaml

# Wait for sync
argocd app wait vault-vals-test --health

# Check the result
kubectl get configmap vals-test-result -n default -o yaml
```

### Expected Output

The ConfigMap should contain actual secret values (not `ref+vault://...`):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vals-test-result
  namespace: default
data:
  foo: bar
  message: Hello from Vault
  number: "42"
  test-passed: "true"
```

### Verify ArgoCD Sync

```bash
# Check sync status
argocd app get vault-vals-test

# Should show:
# Sync Status: Synced
# Health Status: Healthy
```

### Troubleshooting

**Problem:** ArgoCD sync fails with Vault connection error

**Check repo-server can reach Vault:**
```bash
kubectl exec -n argocd deploy/argocd-repo-server -- \
  curl -s http://vault.security:8200/v1/sys/health
```

**Check environment variables:**
```bash
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq '.[] | select(.name | startswith("VAULT"))'
```

**Check repo-server logs:**
```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100 | grep -i vault
```

**Problem:** Vault is sealed

**Solution:** Unseal Vault:
```bash
kubectl exec -n security vault-0 -- vault status

# If sealed:
kubectl exec -n security vault-0 -- vault operator unseal <key-1>
kubectl exec -n security vault-0 -- vault operator unseal <key-2>
kubectl exec -n security vault-0 -- vault operator unseal <key-3>
```

---

## Cleanup

### Remove Local Test

```bash
# Stop port-forward
pkill -f "kubectl port-forward.*vault"
```

### Remove ArgoCD Test

```bash
# Delete the application
argocd app delete vault-vals-test --yes

# Or via kubectl
kubectl delete application vault-vals-test -n argocd

# Remove the ConfigMap
kubectl delete configmap vals-test-result -n default
```

### Remove Test Secret from Vault (Optional)

```bash
export ROOT_TOKEN="<your-root-token>"

kubectl exec -n security vault-0 -- sh -c "
export VAULT_TOKEN=\"$ROOT_TOKEN\"
vault kv delete kv/test/vals-example
"
```

---

## Success Criteria

✅ Local helmfile template shows actual secret values
✅ ArgoCD syncs successfully without errors
✅ ConfigMap contains actual values (not refs)
✅ No `ref+vault://...` strings in deployed resources

If all checks pass, Vault + Vals is working correctly!
