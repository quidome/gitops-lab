# HashiCorp Vault

HashiCorp Vault deployment for UI-based secret management.

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

## Token & User Management

### Understanding Vault Tokens

Vault uses different tokens for different purposes. Here's what you need to know:

| Token Type | Purpose | Lifespan | Who Uses It |
|------------|---------|----------|-------------|
| **Root Token** | Emergency admin access | Forever | You (store securely!) |
| **Admin User** | Daily UI/CLI access | Session-based | You (login with username/password) |
| **Vals Reader** | ArgoCD secret fetching | 1 year (auto-renews) | ArgoCD/Helmfile |
| **AppRole** | External Secrets sync | 1-4 hours (auto-renews) | External Secrets Operator |

**Best Practice:** Use the root token ONLY for emergency recovery and creating other tokens. Use an admin user account for daily operations.

### Creating an Admin User (Recommended)

Instead of using the root token daily, create a user account:

#### 1. Enable Userpass Authentication

```bash
# Set root token
export VAULT_TOKEN="<your-root-token>"

# Enable userpass auth in Vault
kubectl exec -n security vault-0 -- env VAULT_TOKEN="${VAULT_TOKEN}" \
  vault auth enable userpass
```

Or in the Vault UI (http://vault.quido.me):
1. Go to **Access** → **Enable new method**
2. Select **Username & Password**
3. Leave path as `userpass`
4. Click **Enable Method**

#### 2. Create Admin Policy

```bash
# Create policy with read/write access to secrets
kubectl exec -i -n security vault-0 -- env VAULT_TOKEN="${VAULT_TOKEN}" \
  vault policy write admin - <<'EOF'
# Full access to KV secrets
path "kv/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "kv/metadata/*" {
  capabilities = ["list", "read", "delete"]
}

# Ability to list auth methods and policies
path "sys/auth" {
  capabilities = ["read"]
}
path "sys/policies/acl" {
  capabilities = ["list"]
}
EOF
```

Or in the Vault UI:
1. Go to **Policies** → **Create ACL policy**
2. Name: `admin`
3. Paste the policy above
4. Click **Create policy**

#### 3. Create Your User Account

```bash
# Create user with admin policy
kubectl exec -n security vault-0 -- env VAULT_TOKEN="${VAULT_TOKEN}" \
  vault write auth/userpass/users/<your-username> \
  password="<your-password>" \
  policies="admin"
```

Or in the Vault UI (after enabling userpass):
1. Go to **Access** → **userpass** → **Create user**
2. Username: (your choice)
3. Password: (your choice)
4. Policies: Select `admin`
5. Click **Save**

#### 4. Login with Your User Account

In the Vault UI:
1. Sign out from root token
2. Method: **Username**
3. Enter your username and password
4. Click **Sign In**

Now you can manage secrets without using the root token!

### Token Rotation & Refresh

#### When the Vals Reader Token Expires

**Symptoms:**
- ArgoCD sync fails with "permission denied" or "invalid token"
- Applications using Helmfile with `fetchSecretValue` fail to deploy

**Solution:**

```bash
# 1. Create new vals-reader token
export VAULT_TOKEN="<your-root-token-or-admin-token>"

NEW_TOKEN=$(kubectl exec -n security vault-0 -- env VAULT_TOKEN="${VAULT_TOKEN}" \
  vault token create -policy=vals-reader -period=8760h -display-name="vals-reader" \
  -format=json | jq -r '.auth.client_token')

# 2. Update ArgoCD secret
kubectl create secret generic vault-token -n gitops \
  --from-literal=token="$NEW_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Restart ArgoCD repo-server
kubectl rollout restart deployment argocd-repo-server -n gitops
kubectl rollout status deployment argocd-repo-server -n gitops

echo "New vals-reader token: $NEW_TOKEN"
```

**Note:** The vals-reader policy must exist first. If it doesn't, see `VALS-SETUP.md` for complete setup.

#### When the AppRole Token Expires

**Symptoms:**
- External Secrets show "SecretSyncedError" status
- External Secrets operator logs show authentication errors

**Solution:**

AppRole tokens auto-renew, but if the secret-id expires, regenerate it:

```bash
export VAULT_TOKEN="<your-root-token-or-admin-token>"

# Generate new secret-id
SECRET_ID=$(kubectl exec -n security vault-0 -- env VAULT_TOKEN="${VAULT_TOKEN}" \
  vault write -f auth/approle/role/external-secrets/secret-id \
  -format=json | jq -r '.data.secret_id')

# Get existing role-id
ROLE_ID=$(kubectl get secret vault-approle -n security -o jsonpath='{.data.role-id}' | base64 -d)

# Update the secret
kubectl create secret generic vault-approle -n security \
  --from-literal=role-id="$ROLE_ID" \
  --from-literal=secret-id="$SECRET_ID" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Recovery Scenarios

#### Lost Access to Vault (Token Expired/Invalid)

**Option 1: Use AppRole (if still valid)**

```bash
# Get AppRole credentials
ROLE_ID=$(kubectl get secret vault-approle -n security -o jsonpath='{.data.role-id}' | base64 -d)
SECRET_ID=$(kubectl get secret vault-approle -n security -o jsonpath='{.data.secret-id}' | base64 -d)

# Login with AppRole
kubectl exec -n security vault-0 -- vault write auth/approle/login \
  role_id="$ROLE_ID" secret_id="$SECRET_ID"
```

Use the returned `client_token` to access Vault UI or create new tokens.

**Option 2: Generate New Root Token (if you have unseal keys)**

```bash
# Start root token generation
kubectl exec -n security vault-0 -- vault operator generate-root -init
# Save the OTP and nonce!

# Provide 3 unseal keys
kubectl exec -n security vault-0 -- vault operator generate-root -nonce=<nonce>
# Repeat 3 times with different unseal keys

# Decode the root token
kubectl exec -n security vault-0 -- vault operator generate-root \
  -decode=<encoded-token> -otp=<otp>
```

**Option 3: Reset Vault (LAST RESORT - loses all secrets)**

```bash
kubectl delete pvc data-vault-0 -n security
kubectl delete pod vault-0 -n security
# Wait for pod to restart
kubectl exec -n security vault-0 -- vault operator init
```

#### Vault is Sealed After Pod Restart

**Check status:**
```bash
kubectl exec -n security vault-0 -- vault status
```

If `Sealed: true`, unseal with 3 of your 5 unseal keys:

```bash
kubectl exec -n security vault-0 -- vault operator unseal <key-1>
kubectl exec -n security vault-0 -- vault operator unseal <key-2>
kubectl exec -n security vault-0 -- vault operator unseal <key-3>
```

**Note:** Vault always seals on pod restart. This is expected behavior without auto-unseal configuration.

### Security Best Practices

✅ **DO:**
- Store root token and unseal keys securely offline
- Use admin user account for daily operations
- Rotate vals-reader token annually
- Keep AppRole credentials restricted to `security` namespace

❌ **DON'T:**
- Use root token for daily operations
- Store tokens in Git repositories
- Share tokens between environments
- Disable authentication for convenience

## Disaster Recovery

### What to Back Up

Critical data that MUST be backed up securely:

1. **Unseal Keys** (5 keys, need 3 to unseal)
2. **Root Token** (for emergency access)
3. **Vault Data** (all secrets and configuration)
4. **Admin User Credentials** (username/password for daily access)

### Backup Procedures

#### 1. Initial Backup (After vault operator init)

When you first initialize Vault, save this output immediately:

```bash
kubectl exec -n security vault-0 -- vault operator init > vault-init-keys.txt
```

**Store `vault-init-keys.txt` securely:**
- Offline storage (USB drive, paper backup)
- Password manager (1Password, Bitwarden, etc.)
- Encrypted archive in a secure location

**NEVER commit this file to Git!**

#### 2. Data Backup (Regular Schedule)

Vault stores all data in the PersistentVolume. Back up the PVC data regularly.

**Option A: Snapshot via TrueNAS**

If using TrueNAS iSCSI backend:
1. Create ZFS snapshot of the Vault dataset
2. Replicate snapshot to backup location
3. Schedule: Daily snapshots, retain 30 days

**Option B: Vault Snapshot (Enterprise/Manual)**

For manual backups:

```bash
# Export all secrets (requires root or admin token)
export VAULT_TOKEN="<your-token>"

# List all secret paths
kubectl exec -n security vault-0 -- env VAULT_TOKEN="${VAULT_TOKEN}" \
  vault kv list -format=json kv/ > secret-paths.json

# Create backup script to export all secrets
# (Store output securely, contains plaintext secrets!)
```

**Option C: PVC Backup via Kubernetes**

```bash
# Create temporary pod to access PVC
kubectl run vault-backup --rm -it --restart=Never \
  -n security \
  --image=alpine:latest \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "vault-backup",
      "image": "alpine:latest",
      "command": ["tar", "czf", "/backup/vault-data.tar.gz", "/vault/data"],
      "volumeMounts": [{
        "name": "vault-data",
        "mountPath": "/vault/data"
      }, {
        "name": "backup",
        "mountPath": "/backup"
      }]
    }],
    "volumes": [{
      "name": "vault-data",
      "persistentVolumeClaim": {"claimName": "data-vault-0"}
    }, {
      "name": "backup",
      "emptyDir": {}
    }]
  }
}'

# Copy backup out of cluster
kubectl cp security/vault-backup:/backup/vault-data.tar.gz ./vault-data-$(date +%Y%m%d).tar.gz
```

**Backup Schedule Recommendation:**
- **Daily**: Automated PVC/ZFS snapshots
- **Weekly**: Manual verification of backup integrity
- **Monthly**: Full DR drill (restore to test environment)
- **Before major changes**: Ad-hoc backup before upgrades/migrations

#### 3. Configuration Backup

Back up Vault configuration files:

```bash
# Export enabled auth methods
kubectl exec -n security vault-0 -- vault auth list -format=json > vault-auth-methods.json

# Export policies
kubectl exec -n security vault-0 -- vault policy list -format=json > vault-policies.json

# Export AppRole configuration
kubectl exec -n security vault-0 -- env VAULT_TOKEN="${VAULT_TOKEN}" \
  vault read -format=json auth/approle/role/external-secrets > vault-approle-config.json
```

### Restore Procedures

#### Scenario 1: Restore from PVC Backup

**When to use:** Complete data loss, PVC corrupted, accidental deletion

```bash
# 1. Delete existing Vault (if present)
kubectl delete pod vault-0 -n security
kubectl delete pvc data-vault-0 -n security

# 2. Restore PVC data from backup
# (Method depends on your backup solution - TrueNAS restore, Velero, etc.)

# 3. Recreate pod (will use restored PVC)
kubectl apply -f infrastructure/security/vault/helmfile.yaml

# 4. Unseal Vault
kubectl exec -n security vault-0 -- vault operator unseal <key-1>
kubectl exec -n security vault-0 -- vault operator unseal <key-2>
kubectl exec -n security vault-0 -- vault operator unseal <key-3>

# 5. Verify secrets
kubectl exec -n security vault-0 -- env VAULT_TOKEN="${VAULT_TOKEN}" \
  vault kv list kv/
```

#### Scenario 2: Migrate to New Cluster

**When to use:** Moving to new hardware, cluster rebuild

```bash
# On OLD cluster:
# 1. Create full backup (see Backup Procedures above)

# On NEW cluster:
# 1. Deploy Vault (don't initialize yet)
kubectl apply -f infrastructure/security/vault/helmfile.yaml

# 2. Stop Vault pod
kubectl scale statefulset vault -n security --replicas=0

# 3. Restore PVC data from backup
# (Use your backup tool to restore to new PVC)

# 4. Start Vault
kubectl scale statefulset vault -n security --replicas=1

# 5. Unseal with original keys
kubectl exec -n security vault-0 -- vault operator unseal <key-1>
kubectl exec -n security vault-0 -- vault operator unseal <key-2>
kubectl exec -n security vault-0 -- vault operator unseal <key-3>

# 6. Update downstream secrets
# - Rotate vals-reader token (see Token Rotation section)
# - Update AppRole secret-id if needed
# - Restart ArgoCD repo-server
```

#### Scenario 3: Lost Unseal Keys (No Backup)

**Result:** Cannot unseal Vault, all data is encrypted and inaccessible.

**Options:**
1. ❌ **Data is lost** - No recovery possible without unseal keys
2. ✅ **Restore from backup** - If you have a backup of unseal keys
3. ✅ **Reinitialize** - Lose all secrets, start fresh:

```bash
kubectl delete pvc data-vault-0 -n security
kubectl delete pod vault-0 -n security
# Follow Initial Setup from README
```

**Prevention:** Always back up unseal keys immediately after initialization!

### Complete Disaster Recovery Drill

Test your DR plan quarterly:

```bash
# 1. Create test backup
kubectl exec -n security vault-0 -- vault status
# Export current secrets for validation

# 2. Simulate disaster
kubectl delete namespace security

# 3. Restore from backup
# Follow Restore Procedures above

# 4. Validate
# - Vault unsealed successfully
# - All secrets accessible
# - External Secrets syncing
# - ArgoCD can fetch secrets via Vals
# - Applications using secrets are healthy

# 5. Document results
# - Time to restore: ___
# - Issues encountered: ___
# - Improvements needed: ___
```

### Automation Recommendations

**Automated Backup Script (cron job):**

```bash
#!/bin/bash
# /usr/local/bin/backup-vault.sh

BACKUP_DIR="/mnt/backups/vault"
DATE=$(date +%Y%m%d-%H%M%S)

# Create PVC snapshot via your backup tool
# Example for TrueNAS: trigger ZFS snapshot via API

# Export metadata
kubectl exec -n security vault-0 -- vault status > "${BACKUP_DIR}/vault-status-${DATE}.txt"

# Rotate old backups (keep 30 days)
find "${BACKUP_DIR}" -name "vault-*.txt" -mtime +30 -delete

echo "Vault backup completed: ${DATE}"
```

**Add to crontab:**
```bash
0 2 * * * /usr/local/bin/backup-vault.sh
```

### Recovery Time Objective (RTO)

Expected time to restore Vault in various scenarios:

| Scenario | RTO | Requirements |
|----------|-----|--------------|
| Pod restart (sealed) | 5 minutes | Unseal keys available |
| Token expired | 10 minutes | Root token or AppRole valid |
| PVC corruption | 30-60 minutes | Recent backup available |
| Complete cluster loss | 2-4 hours | Full backup + documentation |
| Lost unseal keys | N/A | **Unrecoverable** without backup |

### Critical Success Factors

✅ **Backup:**
- Unseal keys stored in 3+ secure locations
- Automated daily PVC/ZFS snapshots
- Monthly restore validation

✅ **Documentation:**
- Restore procedures tested and documented
- Contact information for backup storage access
- Runbook for common scenarios

✅ **Monitoring:**
- Alert on Vault sealed status
- Alert on backup failures
- Regular DR drill schedule

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

Use this naming convention:
```
kv/<realm>/<application>
```

Examples:
- `kv/home-automation/saic-mqtt-gateway` (keys: `SAIC_USER`, `ABRP_USER_TOKEN`)
- `kv/networking/external-dns` (key: `EXTERNAL_DNS_PIHOLE_PASSWORD`)

## Current State

- Vault is the active secret backend.
- Helmfile uses Vals (`fetchSecretValue`) for deploy-time secret injection.
- External Secrets can use the `vault` `ClusterSecretStore` where runtime syncing is needed.

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

## Notes

For Vals integration details, see `VALS-SETUP.md`.
