# Vals Integration Setup Guide

This guide configures Helmfile to fetch secrets from Vault using the `fetchSecretValue` function.

## Prerequisites

- ✅ Vault deployed and running in `security` namespace
- ✅ Vault unsealed (check with: `kubectl exec -n security vault-0 -- vault status`)
- ✅ KV v2 secrets engine enabled at path `kv`
- ✅ Root token available
- ✅ ArgoCD deployed with Helmfile plugin

## Setup Steps

### 1. Create Read-Only Token for Vals

Set your root token:
```bash
export ROOT_TOKEN="<paste-your-root-token-here>"
```

Create the read-only policy:
```bash
kubectl exec -n security vault-0 -- sh -c "
export VAULT_TOKEN=\"$ROOT_TOKEN\"

cat <<'EOF' | vault policy write vals-reader -
path \"kv/data/*\" {
  capabilities = [\"read\"]
}
path \"kv/metadata/*\" {
  capabilities = [\"list\", \"read\"]
}
EOF
"
```

Create a token with this policy (1 year TTL, auto-renewing):
```bash
kubectl exec -n security vault-0 -- sh -c "
export VAULT_TOKEN=\"$ROOT_TOKEN\"

vault token create \
  -policy=vals-reader \
  -period=8760h \
  -display-name=\"vals-reader\"
"
```

**Save the token** from the output (starts with `hvs.`).

### 2. Configure ArgoCD

Store the vals-reader token:
```bash
export VALS_TOKEN="<paste-vals-reader-token-here>"

kubectl create secret generic vault-token \
  -n gitops \
  --from-literal=token="$VALS_TOKEN"
```

Patch ArgoCD repo-server to use Vault:

**Step 2a: Add env vars to main repo-server container:**
```bash
kubectl patch deployment argocd-repo-server -n gitops --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "VAULT_ADDR",
      "value": "http://vault.security:8200"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "VAULT_TOKEN",
      "valueFrom": {
        "secretKeyRef": {
          "name": "vault-token",
          "key": "token"
        }
      }
    }
  }
]'
```

**Step 2b: Add env vars to helmfile-plugin container:**
```bash
kubectl patch deployment argocd-repo-server -n gitops --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/2/env",
    "value": [
      {
        "name": "VAULT_ADDR",
        "value": "http://vault.security:8200"
      },
      {
        "name": "VAULT_TOKEN",
        "valueFrom": {
          "secretKeyRef": {
            "name": "vault-token",
            "key": "token"
          }
        }
      }
    ]
  }
]'
```

**Note:** Container index 2 is the `helmfile-plugin` sidecar. This is critical - Vals runs inside the helmfile-plugin container, not the main repo-server.

Wait for rollout:
```bash
kubectl rollout status deployment argocd-repo-server -n gitops
```

Verify the patch:
```bash
# Check main repo-server container
kubectl get deployment argocd-repo-server -n gitops -o jsonpath='{.spec.template.spec.containers[0].env}' | jq '.[] | select(.name | startswith("VAULT"))'

# Check helmfile-plugin container (most important!)
kubectl get deployment argocd-repo-server -n gitops -o jsonpath='{.spec.template.spec.containers[2].env}' | jq '.[] | select(.name | startswith("VAULT"))'
```

Both should show `VAULT_ADDR` and `VAULT_TOKEN` variables.

### 3. Setup Local Development Environment

For local `helmfile` commands, set environment variables:

```bash
# Port-forward to Vault (run in separate terminal or background)
kubectl port-forward -n security svc/vault 8200:8200 &

# Set environment variables
export VAULT_ADDR=http://localhost:8200
export VALS_TOKEN="<paste-vals-reader-token-here>"
export VAULT_TOKEN="$VALS_TOKEN"  # Vals looks for VAULT_TOKEN
```

**Tip:** Add these to your shell profile for persistence:
```bash
# Add to ~/.bashrc or ~/.zshrc
alias vault-dev='kubectl port-forward -n security svc/vault 8200:8200 & export VAULT_ADDR=http://localhost:8200 && export VAULT_TOKEN=<your-vals-token>'
```

## Using Vals in Helmfile

### Basic Syntax

In any `helmfile.yaml.gotmpl`:

```yaml
environments:
  default:
    values:
      - mySecret: {{ fetchSecretValue "ref+vault://kv/realm/app#key" }}
      - anotherSecret: {{ fetchSecretValue "ref+vault://kv/realm/app#password" }}

releases:
  - name: myapp
    namespace: myrealm
    chart: ./helm-chart
    values:
      - config:
          secret: {{ .Values.mySecret | quote }}
          password: {{ .Values.anotherSecret | quote }}
```

### Vault Path Convention

Follow the existing pattern:
```
kv/<realm>/<application>  (secret path)
  ├── key1                (property)
  ├── key2                (property)
  └── key3                (property)
```

**Examples:**
- `kv/home-automation/zigbee2mqtt#network-key`
- `kv/home-automation/saic-mqtt-gateway#SAIC_USER`
- `kv/networking/external-dns#pihole-password`

### Reference Syntax

```yaml
# Basic reference
{{ fetchSecretValue "ref+vault://kv/path/to/secret#key" }}

# Multiple keys from same secret
username: {{ fetchSecretValue "ref+vault://kv/app/creds#username" }}
password: {{ fetchSecretValue "ref+vault://kv/app/creds#password" }}
```

## Refreshing Secrets After Vault Changes

**Important:** Vals fetches secrets at **deploy-time**, not runtime. When you change a secret in Vault, you must trigger a re-deployment.

### Via ArgoCD (Recommended)

```bash
# Sync the application to fetch updated secrets
kubectl patch application home-automation-saic-mqtt-gateway -n gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'

# Wait for deployment to complete
kubectl wait --for=jsonpath='{.status.health.status}'=Healthy application/home-automation-saic-mqtt-gateway -n gitops --timeout=180s
```

**What happens:**
1. ArgoCD runs `helmfile template`
2. Vals fetches current secret values from Vault
3. K8s Secret object is updated
4. Deployment detects change and restarts pod
5. Pod loads new secret values

### Via Local Helmfile

```bash
# Set up Vault access
export VAULT_TOKEN="<vals-token>"
kubectl port-forward -n security svc/vault 8200:8200 &
export VAULT_ADDR=http://localhost:8200

# Apply changes
cd /home/quidome/dev/github.com/quidome/gitops-lab
helmfile -f applications/home-automation/saic-mqtt-gateway/helmfile.yaml.gotmpl apply
```

### Comparison: Vals vs External Secrets

| Aspect | Vals (Deploy-time) | External Secrets (Runtime) |
|--------|-------------------|---------------------------|
| **Secret fetch** | During ArgoCD sync | Continuous (every 1h) |
| **Change in Vault** | No automatic update | Auto-syncs within 1h |
| **To apply changes** | Trigger ArgoCD sync via `kubectl patch application ...` | Wait or delete pod |
| **Secret staleness** | Until next deployment | Max 1 hour |
| **Best for** | App-specific, static secrets | Shared, frequently updated secrets |

## Testing

### Test Vals Locally

If you have vals CLI installed:
```bash
vals eval "ref+vault://kv/test/example#foo"
```

### Test Helmfile Template

```bash
# With port-forward and VAULT_TOKEN set
helmfile -f applications/your-app/helmfile.yaml.gotmpl template
```

Check that secret values appear (not `ref+vault://...` strings).

### Test ArgoCD Sync

```bash
# Trigger sync
kubectl patch application <your-app> -n gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'

# Check for errors
kubectl get application <your-app> -n gitops -o yaml

# If sync fails, check repo-server logs
kubectl logs -n gitops -l app.kubernetes.io/name=argocd-repo-server --tail=50 | grep -i vault
```

## Troubleshooting

### Problem: "permission denied" when fetching secret

**Check token has correct policy:**
```bash
kubectl exec -n security vault-0 -- sh -c "
export VAULT_TOKEN=\"$ROOT_TOKEN\"
vault token lookup <vals-token>
"
```

Should show `vals-reader` in policies.

### Problem: ArgoCD sync fails with "dial tcp 127.0.0.1:8200: connect: connection refused"

**Cause:** VAULT_ADDR not set in helmfile-plugin container (Vals runs there, not in main repo-server).

**Solution:** Check both containers have VAULT env vars:
```bash
# Main repo-server container
kubectl exec -n gitops deploy/argocd-repo-server -c repo-server -- sh -c 'printenv | grep VAULT'

# Helmfile-plugin container (CRITICAL - this is where Vals runs!)
kubectl exec -n gitops deploy/argocd-repo-server -c helmfile-plugin -- sh -c 'printenv | grep VAULT'
```

If helmfile-plugin is missing variables, patch it:
```bash
kubectl patch deployment argocd-repo-server -n gitops --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/2/env",
    "value": [
      {
        "name": "VAULT_ADDR",
        "value": "http://vault.security:8200"
      },
      {
        "name": "VAULT_TOKEN",
        "valueFrom": {
          "secretKeyRef": {
            "name": "vault-token",
            "key": "token"
          }
        }
      }
    ]
  }
]'

kubectl rollout status deployment argocd-repo-server -n gitops
```

### Problem: ArgoCD sync fails with other Vault connection error

**Check repo-server can reach Vault:**
```bash
kubectl exec -n gitops deploy/argocd-repo-server -c helmfile-plugin -- sh -c 'printenv | grep VAULT'
```

Should show both `VAULT_ADDR` and `VAULT_TOKEN`.

**Check Vault is accessible:**
```bash
kubectl run -n gitops vault-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://vault.security:8200/v1/sys/health
```

Should return JSON with `sealed: false`.

### Problem: Local helmfile returns "ref+vault://..." literally

**Check environment variables:**
```bash
echo $VAULT_ADDR
echo $VAULT_TOKEN
```

Both should be set. If empty, re-export them.

### Problem: Vault is sealed

**Check seal status:**
```bash
kubectl exec -n security vault-0 -- vault status
```

If `Sealed: true`, unseal manually:
```bash
kubectl exec -n security vault-0 -- vault operator unseal <key-1>
kubectl exec -n security vault-0 -- vault operator unseal <key-2>
kubectl exec -n security vault-0 -- vault operator unseal <key-3>
```

**Note:** Vault seals on every pod restart. This is expected behavior without auto-unseal.

## Token Rotation

The vals-reader token has a 1-year period and renews automatically. To rotate:

```bash
# Revoke old token
kubectl exec -n security vault-0 -- sh -c "
export VAULT_TOKEN=\"$ROOT_TOKEN\"
vault token revoke <old-vals-token>
"

# Create new token (follow Step 1 above)

# Update ArgoCD secret
kubectl delete secret vault-token -n gitops
kubectl create secret generic vault-token \
  -n gitops \
  --from-literal=token="<new-vals-token>"

# Restart repo-server to pick up new token
kubectl rollout restart deployment argocd-repo-server -n gitops
```

## When to Use Vals vs External Secrets

### Use Vals (deploy-time secret fetch):
- ✅ App-specific secrets (not shared)
- ✅ Secrets templated into config files
- ✅ Relatively static secrets

**Examples:** Zigbee2MQTT network key, app API tokens

### Use External Secrets (runtime secret sync):
- ✅ Secrets shared by multiple apps
- ✅ Secrets needing automatic rotation
- ✅ Frequently updated secrets

**Examples:** MQTT credentials, database passwords

**You can use both!** Many apps benefit from a hybrid approach.

## Security Notes

- ✅ Read-only token limits blast radius (can't modify/delete secrets)
- ✅ Token has 1-year TTL with auto-renewal
- ⚠️ Token stored in K8s secret (encrypted at rest by K8s)
- ⚠️ Anyone with kubectl access to gitops namespace can read token
- ⚠️ Vault must be unsealed for Vals to work

**Acceptable for home lab** where you control cluster access.

## References

- Vals documentation: https://github.com/helmfile/vals
- Vault KV v2 API: https://developer.hashicorp.com/vault/api-docs/secret/kv/kv-v2
- Full implementation spec: `VALS-IMPLEMENTATION-SPEC.md`
