# HashiCorp Vault

HashiCorp Vault deployment for UI-based secret management. Runs alongside OpenBao for gradual migration.

## Deployment

- **Namespace**: `security`
- **Storage**: 1Gi iSCSI (truenas-iscsi)
- **Mode**: Standalone
- **UI Access**: http://vault.quido.me

## Initial Setup

### 1. Initialize Vault (First Time Only)

```bash
kubectl exec -n security vault-0 -- vault operator init
```

**Save the output securely:**
- 5 unseal keys (need 3 to unseal)
- 1 root token (for admin access)

### 2. Unseal Vault

Required after every pod restart:

```bash
# Use 3 of your 5 unseal keys
kubectl exec -n security vault-0 -- vault operator unseal <key-1>
kubectl exec -n security vault-0 -- vault operator unseal <key-2>
kubectl exec -n security vault-0 -- vault operator unseal <key-3>
```

### 3. Check Status

```bash
kubectl exec -n security vault-0 -- vault status
```

Look for `Sealed: false`

## AppRole Setup for External Secrets

### 1. Configure AppRole Authentication

```bash
# Set your root token
export VAULT_TOKEN="<your-root-token>"

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

# Get the role-id
kubectl exec -n security vault-0 -- vault read auth/approle/role/external-secrets/role-id

# Generate a secret-id
kubectl exec -n security vault-0 -- vault write -f auth/approle/role/external-secrets/secret-id
```

### 2. Create Kubernetes Secret

```bash
kubectl create secret generic vault-approle \
  -n security \
  --from-literal=role-id="<role-id-from-above>" \
  --from-literal=secret-id="<secret-id-from-above>"
```

### 3. Deploy ClusterSecretStore

The `vault-config` release will automatically create a `ClusterSecretStore` named `vault` that External Secrets can use.

```bash
# Verify it's created
kubectl get clustersecretstore vault
```

## Using Vault with External Secrets

### Enable KV v2 Engine (First Time)

In the Vault UI (http://vault.quido.me):
1. Go to "Secrets Engines" → "Enable new engine"
2. Select "KV" (Key-Value)
3. Set path to `kv`
4. Choose version 2

### Create Secrets

Use the same naming convention as OpenBao:
```
kv/<realm>/<application>/<property>
```

Examples:
- `kv/home-automation/saic-mqtt-gateway/SAIC_USER`
- `kv/home-automation/saic-mqtt-gateway/ABRP_USER_TOKEN`
- `kv/networking/external-dns/pihole-password`

### Migrate an Application

**Before (using OpenBao):**
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-app
spec:
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  # ... rest of config
```

**After (using Vault):**
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-app
spec:
  secretStoreRef:
    name: vault  # <-- Just change this!
    kind: ClusterSecretStore
  # ... rest of config (paths stay the same)
```

## Migration Strategy

1. **Add secrets to Vault** via UI (same paths as OpenBao)
2. **Change one ExternalSecret at a time** to use `vault` ClusterSecretStore
3. **Test the application** to ensure it still works
4. **Repeat** for each application
5. **Decommission OpenBao** once all apps are migrated

No big bang migration needed - run both side-by-side!

## Useful Commands

```bash
# Check vault status
kubectl exec -n security vault-0 -- vault status

# List enabled auth methods
kubectl exec -n security vault-0 -- vault auth list

# List secrets engines
kubectl exec -n security vault-0 -- vault secrets list

# Read a secret (for debugging)
kubectl exec -n security vault-0 -- vault kv get kv/home-automation/mosquitto
```

## Comparison: Vault vs OpenBao

| Feature | Vault | OpenBao |
|---------|-------|---------|
| UI | ✅ Full-featured | ❌ None |
| CLI | ✅ Full | ✅ Full |
| API | ✅ Full | ✅ Full |
| External Secrets | ✅ Supported | ✅ Supported |
| Management | UI makes it easy | CLI only |

**Why both?** Vault provides better UX with the UI, while OpenBao remains as the open-source fork. Gradual migration allows testing without risk.
