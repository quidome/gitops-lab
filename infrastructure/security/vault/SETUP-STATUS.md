# Vault Setup Status

**Last Updated**: 2026-02-13

## Current State

✅ **Completed:**
- Vault deployed to `security` namespace with UI enabled
- HTTPRoute configured at `http://vault.quido.me`
- Vault initialized and unsealed
- Root token and unseal keys saved securely
- Combined config chart created with templated ClusterSecretStore and HTTPRoute
- Documentation created in README.md

⏸️ **In Progress:**
- AppRole authentication configuration
- ClusterSecretStore deployment

❌ **Not Started:**
- Enable KV v2 secrets engine
- Migrate applications from OpenBao to Vault

## Next Steps to Complete Setup

### 1. Configure AppRole Authentication

```bash
# Enable AppRole auth method
kubectl exec -n security vault-0 -- vault auth enable approle

# Create policy for external-secrets (read-only access to kv/*)
kubectl exec -n security vault-0 -- sh -c 'cat <<EOF | vault policy write external-secrets -
path "kv/data/*" {
  capabilities = ["read"]
}
path "kv/metadata/*" {
  capabilities = ["list", "read"]
}
EOF'

# Create AppRole with the policy
kubectl exec -n security vault-0 -- vault write auth/approle/role/external-secrets \
  token_policies="external-secrets" \
  token_ttl=1h \
  token_max_ttl=4h

# Get the role-id (SAVE THIS!)
kubectl exec -n security vault-0 -- vault read auth/approle/role/external-secrets/role-id

# Generate a secret-id (SAVE THIS!)
kubectl exec -n security vault-0 -- vault write -f auth/approle/role/external-secrets/secret-id
```

### 2. Create Kubernetes Secret

```bash
# Replace <role-id> and <secret-id> with values from step 1
kubectl create secret generic vault-approle \
  -n security \
  --from-literal=role-id="<role-id>" \
  --from-literal=secret-id="<secret-id>"
```

### 3. Wait for ArgoCD Sync

The `vault-config` release will automatically deploy the ClusterSecretStore.

```bash
# Verify ClusterSecretStore is created
kubectl get clustersecretstore vault

# Check if it's ready
kubectl get clustersecretstore vault -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

### 4. Enable KV v2 Secrets Engine

In the Vault UI (http://vault.quido.me):
1. Go to "Secrets Engines" → "Enable new engine"
2. Select "KV" (Key-Value)
3. Set path to `kv`
4. Choose version 2

Or via CLI:
```bash
kubectl exec -n security vault-0 -- vault secrets enable -path=kv -version=2 kv
```

### 5. Test with a Secret

Add a test secret in Vault UI:
- Path: `kv/test/example`
- Key: `foo`
- Value: `bar`

Create a test ExternalSecret:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: test-vault
  namespace: security
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: test-vault-secret
  data:
    - secretKey: foo
      remoteRef:
        key: test/example
        property: foo
```

```bash
# Apply and check
kubectl apply -f test-external-secret.yaml
kubectl get secret test-vault-secret -n security -o yaml
```

## Migration Strategy

Once the above is complete, you can gradually migrate applications:

1. **Add secrets to Vault** (same paths as OpenBao)
   - Example: `kv/home-automation/saic-mqtt-gateway/SAIC_USER`

2. **Update ExternalSecret** to use `vault` instead of `openbao`:
   ```yaml
   secretStoreRef:
     name: vault  # Changed from: openbao
     kind: ClusterSecretStore
   ```

3. **Test the application** works correctly

4. **Repeat** for other applications

5. **Eventually decommission OpenBao** when all migrated

## Files Created This Session

- `infrastructure/security/vault/` - Full Vault deployment
  - `helmfile.yaml.gotmpl` - Releases: vault + vault-config
  - `values.yaml` - Vault server configuration
  - `config/Chart.yaml` - Config chart metadata
  - `config/values.yaml` - Template variables
  - `config/templates/cluster-secret-store.yaml` - Templated ClusterSecretStore
  - `config/templates/http-route.yaml` - Templated HTTPRoute
  - `README.md` - Full documentation
  - `SETUP-STATUS.md` - This file

- `applications/home-automation/saic-mqtt-gateway/README.md` - ABRP documentation

## Related Documentation

- Full setup instructions: `infrastructure/security/vault/README.md`
- ABRP token setup: `applications/home-automation/saic-mqtt-gateway/README.md`
- OpenBao comparison and migration guide in Vault README

## Notes

- Vault and OpenBao can run side-by-side
- No rush to migrate - test thoroughly first
- Vault UI makes secret management much easier than CLI
- Remember to unseal Vault after pod restarts (need 3 of 5 keys)
