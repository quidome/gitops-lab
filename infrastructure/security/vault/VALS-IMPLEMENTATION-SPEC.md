# Helmfile + Vals Secret Injection Implementation Specification

**Version**: 1.1
**Created**: 2026-02-13
**Updated**: 2026-02-13
**Status**: Implemented
**Owner**: Infrastructure Team

## Table of Contents

1. [Overview](#overview)
2. [Goals and Non-Goals](#goals-and-non-goals)
3. [Prerequisites](#prerequisites)
4. [Decision Points](#decision-points)
5. [Architecture](#architecture)
6. [Implementation Phases](#implementation-phases)
7. [Testing Strategy](#testing-strategy)
8. [Rollback Plan](#rollback-plan)
9. [Maintenance](#maintenance)

---

## Overview

This specification outlines the implementation of Helmfile + Vals integration for secret injection from HashiCorp Vault. The solution will support both local development (workstation) and GitOps (ArgoCD) workflows.

### Current State

- **Secret Management**: OpenBao (CLI-only) + External Secrets Operator
- **GitOps**: ArgoCD with Helmfile plugin
- **Vault Status**: Deployed but not integrated with Helmfile
- **Secret Injection**: External Secrets creates K8s Secret objects at runtime

### Target State

- **Secret Management**: Vault (with UI) + Vals integration + External Secrets (hybrid)
- **Local Development**: Helmfile with Vals fetches secrets via port-forward or direct access
- **ArgoCD**: Helmfile plugin fetches secrets via Kubernetes auth during sync
- **Secret Injection**: Deploy-time (Vals) for static config + Runtime (External Secrets) for shared secrets

---

## Goals and Non-Goals

### Goals

1. Enable Helmfile to fetch secrets from Vault using `fetchSecretValue` syntax
2. Support local development workflow (port-forward + token/AppRole)
3. Support ArgoCD GitOps workflow (Kubernetes auth)
4. Maintain backward compatibility with External Secrets Operator
5. Provide clear migration path from External Secrets to Vals (where appropriate)
6. Document when to use Vals vs External Secrets

### Non-Goals

1. Complete migration away from External Secrets (hybrid approach preferred)
2. Custom Vals plugins or backends beyond Vault
3. Secret encryption at rest (Vault handles this)
4. Secret rotation automation (separate concern)

---

## Prerequisites

### Infrastructure

- [x] Vault deployed in `security` namespace
- [x] Vault initialized and unsealed
- [x] Root token available
- [x] HTTPRoute configured at `http://vault.quido.me`
- [x] External Secrets Operator deployed
- [ ] Vault KV v2 secrets engine enabled at path `kv`
- [ ] Kubernetes auth method enabled in Vault

### Tooling

**Local workstation:**
- [x] kubectl with cluster access
- [x] helmfile installed
- [ ] vals CLI installed (optional, for testing)

**ArgoCD:**
- [x] ArgoCD installed with Helmfile plugin
- [x] ApplicationSet for `applications/*/*` pattern
- [ ] ArgoCD repo-server has network access to Vault service

### Permissions

- [ ] Vault policy for ArgoCD (read-only kv access)
- [ ] Vault policy for developers (read-only kv access)
- [ ] Kubernetes role for Vault (argocd-repo-server service account)

---

## Decision Points

### Decision 1: Authentication Method for ArgoCD

**Options:**

| Option | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| **Kubernetes Auth** | Native K8s integration, no secret management, auto token rotation | Requires Vault config | ✅ **Preferred** |
| **AppRole** | Explicit credentials, works anywhere | Manual secret rotation, requires K8s secret | ❌ Backup only |
| **Token** | Simple | No rotation, security risk | ❌ Development only |

**Decision**: Use **Kubernetes Auth** for ArgoCD, **Token** for local development.

### Decision 2: When to Use Vals vs External Secrets

**Use Vals when:**
- Secrets are app-specific and templated into config files
- Secrets are relatively static (weekly/monthly updates)
- You want secrets resolved at deploy time
- Examples: Zigbee2MQTT network key, app-specific API keys

**Use External Secrets when:**
- Secrets are shared across multiple applications
- Secrets need automatic rotation without redeployment
- Secrets need to exist as K8s Secret objects for legacy apps
- Examples: MQTT credentials (used by 5+ apps), database passwords

**Decision**: **Hybrid approach** - use both patterns based on use case.

### Decision 3: Vault Path Structure

**Current OpenBao convention:**
```
kv/<realm>/<application>/<property>
```

**Proposed Vault convention:**
```
kv/<realm>/<application>  (secret path)
  ├── property1            (key)
  ├── property2            (key)
  └── property3            (key)
```

**Example:**
```
kv/home-automation/zigbee2mqtt
  ├── network-key
  ├── mqtt-username
  └── mqtt-password
```

**Vals reference:**
```yaml
networkKey: {{ fetchSecretValue "ref+vault://kv/home-automation/zigbee2mqtt#network-key" }}
```

**Decision**: **Maintain same path structure** for consistency with OpenBao migration.

### Decision 4: Vault Address Configuration

**Options:**
1. Hardcode in helmfile: `ref+vault://http://vault.security:8200/kv/path#key`
2. Use environment variable: `VAULT_ADDR` (vals default)
3. Helmfile environment values

**Decision**: Use **environment variable** (`VAULT_ADDR`) for flexibility.

---

## Architecture

### Authentication Flow

#### Local Development
```
┌─────────────┐          ┌──────────────┐          ┌─────────┐
│  Developer  │          │  kubectl     │          │  Vault  │
│  Workstation│          │  port-forward│          │  Pod    │
└──────┬──────┘          └──────┬───────┘          └────┬────┘
       │                        │                       │
       │ 1. Port-forward 8200   │                       │
       │───────────────────────>│                       │
       │                        │                       │
       │ 2. export VAULT_TOKEN  │                       │
       │                        │                       │
       │ 3. helmfile apply      │                       │
       │   (vals fetches)       │  4. GET /kv/data/... │
       │────────────────────────┼──────────────────────>│
       │                        │  5. Secret data       │
       │<───────────────────────┼───────────────────────│
       │                        │                       │
```

#### ArgoCD GitOps
```
┌─────────────┐          ┌──────────────┐          ┌─────────┐
│   ArgoCD    │          │    Vault     │          │  K8s    │
│ Repo-Server │          │   Service    │          │  API    │
└──────┬──────┘          └──────┬───────┘          └────┬────┘
       │                        │                       │
       │ 1. Read SA token       │                       │
       │───────────────────────────────────────────────>│
       │                        │                       │
       │ 2. POST /auth/kubernetes/login                 │
       │   (jwt=SA token)       │                       │
       │───────────────────────>│                       │
       │                        │                       │
       │                        │  3. Verify SA token   │
       │                        │──────────────────────>│
       │                        │  4. Token valid       │
       │                        │<──────────────────────│
       │                        │                       │
       │  5. Vault token (24h)  │                       │
       │<───────────────────────│                       │
       │                        │                       │
       │ 6. helmfile template   │                       │
       │   (vals fetches)       │                       │
       │                        │                       │
       │ 7. GET /kv/data/...    │                       │
       │───────────────────────>│                       │
       │ 8. Secret data         │                       │
       │<───────────────────────│                       │
       │                        │                       │
```

### Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│                     Vault (security ns)                  │
│  ┌────────────────┐  ┌──────────────────────────────┐  │
│  │  KV v2 Engine  │  │  Auth Methods                │  │
│  │  Path: kv/     │  │  - Kubernetes (ArgoCD)       │  │
│  │                │  │  - AppRole (backup)          │  │
│  │  Secrets:      │  │  - Token (dev)               │  │
│  │  kv/realm/app  │  │                              │  │
│  └────────────────┘  └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                              ▲
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
┌───────▼────────┐   ┌────────▼───────┐   ┌────────▼─────────┐
│  External      │   │   Helmfile     │   │    Developer     │
│  Secrets Op    │   │   + Vals       │   │    Workstation   │
│                │   │   (ArgoCD)     │   │                  │
│  Runtime       │   │  Deploy-time   │   │   kubectl +      │
│  Secret Sync   │   │  Secret Fetch  │   │   port-forward   │
└────────────────┘   └────────────────┘   └──────────────────┘
        │                     │                     │
        │                     │                     │
        ▼                     ▼                     ▼
┌─────────────────────────────────────────────────────────┐
│            Kubernetes Secrets / ConfigMaps              │
└─────────────────────────────────────────────────────────┘
```

---

## Implementation Phases

### Phase 0: Preparation (1 hour)

**Objective**: Verify prerequisites and prepare environment.

#### Steps

1. **Verify Vault is running and unsealed**
   ```bash
   kubectl exec -n security vault-0 -- vault status
   ```
   Expected: `Sealed: false`

2. **Enable KV v2 secrets engine** (if not already)
   ```bash
   kubectl exec -n security vault-0 -- sh -c '
   export VAULT_TOKEN="<root-token>"
   vault secrets enable -path=kv -version=2 kv
   '
   ```

3. **Verify Vault network connectivity**
   ```bash
   # From ArgoCD namespace
   kubectl run -n argocd vault-test --rm -it --image=curlimages/curl --restart=Never -- \
     curl -s http://vault.security:8200/v1/sys/health | jq
   ```
   Expected: HTTP 200 with sealed=false

4. **Install vals CLI locally** (optional, for testing)
   ```bash
   # macOS
   brew install vals

   # Linux
   curl -Lo vals https://github.com/helmfile/vals/releases/download/v0.37.0/vals_0.37.0_linux_amd64.tar.gz
   tar xf vals*.tar.gz
   sudo mv vals /usr/local/bin/
   ```

#### Deliverables

- [ ] Vault unsealed and healthy
- [ ] KV v2 engine enabled at `kv/`
- [ ] Network connectivity verified
- [ ] vals CLI installed (optional)

#### Success Criteria

```bash
# This should return secret data
kubectl exec -n security vault-0 -- sh -c '
export VAULT_TOKEN="<root-token>"
vault kv put kv/test/vals-test foo=bar
vault kv get kv/test/vals-test
'
```

---

### Phase 1: Vault Kubernetes Auth Setup (30 minutes)

**Objective**: Configure Vault to trust ArgoCD's service account.

#### Steps

1. **Enable Kubernetes auth method**
   ```bash
   kubectl exec -n security vault-0 -- sh -c '
   export VAULT_TOKEN="<root-token>"
   vault auth enable kubernetes
   '
   ```

2. **Configure Kubernetes auth**
   ```bash
   kubectl exec -n security vault-0 -- sh -c '
   export VAULT_TOKEN="<root-token>"
   vault write auth/kubernetes/config \
     kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"
   '
   ```

3. **Create ArgoCD policy**
   ```bash
   kubectl exec -n security vault-0 -- sh -c '
   export VAULT_TOKEN="<root-token>"
   cat <<EOF | vault policy write argocd-reader -
   # Read-only access to all KV secrets
   path "kv/data/*" {
     capabilities = ["read"]
   }
   path "kv/metadata/*" {
     capabilities = ["list", "read"]
   }
   EOF
   '
   ```

4. **Create Kubernetes role for ArgoCD**
   ```bash
   kubectl exec -n security vault-0 -- sh -c '
   export VAULT_TOKEN="<root-token>"
   vault write auth/kubernetes/role/argocd \
     bound_service_account_names=argocd-repo-server \
     bound_service_account_namespaces=argocd \
     policies=argocd-reader \
     ttl=24h
   '
   ```

5. **Verify configuration**
   ```bash
   # List auth methods
   kubectl exec -n security vault-0 -- vault auth list

   # Read the role
   kubectl exec -n security vault-0 -- sh -c '
   export VAULT_TOKEN="<root-token>"
   vault read auth/kubernetes/role/argocd
   '
   ```

#### Deliverables

- [ ] Kubernetes auth enabled
- [ ] ArgoCD policy created
- [ ] Kubernetes role created for argocd-repo-server

#### Success Criteria

```bash
# Test authentication from ArgoCD namespace
kubectl run -n argocd vault-auth-test --rm -it --image=hashicorp/vault:latest --restart=Never -- sh -c '
export VAULT_ADDR=http://vault.security:8200
export SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

vault write auth/kubernetes/login \
  role=argocd \
  jwt=$SA_TOKEN
'
```

Expected: Returns a Vault token with 24h TTL.

---

### Phase 2: Local Development Setup (15 minutes)

**Objective**: Enable developers to use Helmfile + Vals locally.

#### Steps

1. **Create developer helper script**

Create `scripts/vault-dev-env.sh`:

```bash
#!/bin/bash
set -e

VAULT_NAMESPACE="${VAULT_NAMESPACE:-security}"
VAULT_PORT="${VAULT_PORT:-8200}"

echo "🔐 Setting up Vault environment for local development..."

# Check if port-forward is already running
if lsof -Pi :$VAULT_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "✅ Port $VAULT_PORT already in use (port-forward may be running)"
else
  echo "📡 Starting port-forward to Vault..."
  kubectl port-forward -n $VAULT_NAMESPACE svc/vault $VAULT_PORT:8200 &
  PF_PID=$!
  echo "   PID: $PF_PID"

  # Wait for port-forward to be ready
  sleep 2
fi

export VAULT_ADDR="http://localhost:$VAULT_PORT"
echo "✅ VAULT_ADDR=$VAULT_ADDR"

# Check if token is already set
if [ -n "$VAULT_TOKEN" ]; then
  echo "✅ VAULT_TOKEN already set"
else
  echo "⚠️  VAULT_TOKEN not set"
  echo "   Please run: export VAULT_TOKEN=<your-token>"
  echo "   Or set in your shell profile for persistent access"
fi

# Verify connectivity
echo ""
echo "🔍 Testing Vault connectivity..."
if curl -s $VAULT_ADDR/v1/sys/health | jq -e '.sealed == false' >/dev/null 2>&1; then
  echo "✅ Vault is unsealed and accessible"
else
  echo "❌ Cannot connect to Vault or Vault is sealed"
  exit 1
fi

echo ""
echo "🎉 Ready! You can now run helmfile commands."
echo "   Example: helmfile -f applications/home-automation/zigbee2mqtt/helmfile.yaml.gotmpl template"
```

2. **Create test Helmfile**

Create `infrastructure/security/vault/examples/test-vals.yaml`:

```yaml
environments:
  default:
    values:
      - testSecret: {{ fetchSecretValue "ref+vault://kv/test/vals-test#foo" }}

releases:
  - name: test-vals
    namespace: default
    chart: stable/raw
    values:
      - resources:
          - apiVersion: v1
            kind: ConfigMap
            metadata:
              name: vals-test
            data:
              secret-value: {{ .Values.testSecret | quote }}
```

3. **Document usage**

Add to `infrastructure/security/vault/README.md`:

```markdown
## Local Development with Vals

### Setup

1. Start port-forward and set environment:
   ```bash
   source scripts/vault-dev-env.sh
   export VAULT_TOKEN=<your-root-token>
   ```

2. Test Vals integration:
   ```bash
   helmfile -f infrastructure/security/vault/examples/test-vals.yaml template
   ```

3. Run your application helmfile:
   ```bash
   helmfile -f applications/home-automation/myapp/helmfile.yaml.gotmpl apply
   ```

### Tips

- Add `export VAULT_TOKEN=<token>` to `~/.bashrc` or `~/.zshrc` for persistence
- Use `kubectl port-forward` in a separate terminal for long sessions
- Test secret access with: `vals eval "ref+vault://kv/path#key"`
```

#### Deliverables

- [ ] `scripts/vault-dev-env.sh` created
- [ ] Test Helmfile created
- [ ] Documentation updated

#### Success Criteria

```bash
# Developer runs this sequence successfully
source scripts/vault-dev-env.sh
export VAULT_TOKEN=<token>
helmfile -f infrastructure/security/vault/examples/test-vals.yaml template

# Output shows actual secret value, not "ref+vault://..."
```

---

### Phase 3: ArgoCD Integration (30 minutes)

**Objective**: Configure ArgoCD to use Vals with Kubernetes auth.

#### Steps

1. **Verify ArgoCD Helmfile plugin configuration**

Check existing plugin in `infrastructure-legacy/controllers/argocd/`:

```bash
kubectl get configmap argocd-cm -n argocd -o yaml
```

Look for helmfile plugin configuration. Should include vals support (built-in to helmfile).

2. **Set Vault address for ArgoCD repo-server**

Since ArgoCD runs in-cluster, it should use the service DNS name:

```bash
kubectl patch deployment argocd-repo-server -n argocd --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "VAULT_ADDR",
      "value": "http://vault.security:8200"
    }
  }
]'
```

**Alternative (GitOps-friendly)**: Add to ArgoCD kustomization:

Create `infrastructure-legacy/controllers/argocd/repo-server-env-patch.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-repo-server
spec:
  template:
    spec:
      containers:
      - name: repo-server
        env:
        - name: VAULT_ADDR
          value: "http://vault.security:8200"
        - name: VAULT_AUTH_METHOD
          value: "kubernetes"
        - name: VAULT_ROLE
          value: "argocd"
```

Add to `infrastructure-legacy/controllers/argocd/kustomization.yaml`:

```yaml
patchesStrategicMerge:
  - repo-server-env-patch.yaml
```

3. **Restart repo-server to apply changes**

```bash
kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl rollout status deployment argocd-repo-server -n argocd
```

4. **Create test Application**

Create `infrastructure/security/vault/examples/test-argocd-vals.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-vals-integration
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/quidome/gitops-lab.git
    targetRevision: main
    path: infrastructure/security/vault/examples
    plugin:
      name: helmfile
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

5. **Test ArgoCD sync**

```bash
kubectl apply -f infrastructure/security/vault/examples/test-argocd-vals.yaml
argocd app sync test-vals-integration
argocd app get test-vals-integration
```

#### Deliverables

- [ ] VAULT_ADDR set for argocd-repo-server
- [ ] Kubernetes auth method configured
- [ ] Test Application created and synced
- [ ] ArgoCD kustomization updated (GitOps)

#### Success Criteria

```bash
# ArgoCD successfully syncs app with Vals references
argocd app get test-vals-integration --show-operation

# Check generated ConfigMap has actual secret value
kubectl get configmap vals-test -o yaml
# Should show: secret-value: "bar" (not "ref+vault://...")
```

#### Troubleshooting

If sync fails, check logs:

```bash
# Check repo-server logs for Vals/Vault errors
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100 | grep -i vault

# Check if repo-server can reach Vault
kubectl exec -n argocd deploy/argocd-repo-server -- curl -s http://vault.security:8200/v1/sys/health

# Check if Kubernetes auth works from repo-server
kubectl exec -n argocd deploy/argocd-repo-server -- sh -c '
export VAULT_ADDR=http://vault.security:8200
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s --request POST --data "{\"jwt\": \"$SA_TOKEN\", \"role\": \"argocd\"}" \
  $VAULT_ADDR/v1/auth/kubernetes/login | jq
'
```

---

### Phase 4: Migrate First Application (1 hour)

**Objective**: Migrate one application from External Secrets to Vals as proof-of-concept.

#### Candidate Selection

**Good candidates:**
- Small, non-critical apps
- App-specific secrets (not shared)
- Static secrets that rarely change

**Suggested:** `applications/home-automation/zigbee2mqtt`

#### Migration Steps

1. **Add secrets to Vault**

```bash
# Copy secrets from OpenBao to Vault (or add via UI)
kubectl exec -n security openbao-0 -- sh -c '
export BAO_TOKEN="<openbao-token>"
bao kv get -format=json kv/home-automation/zigbee2mqtt
' > /tmp/z2m-secrets.json

# Extract values and add to Vault via UI at http://vault.quido.me
# Path: kv/home-automation/zigbee2mqtt
# Keys: network-key, mqtt-username, mqtt-password, etc.
```

2. **Update Helmfile to use Vals**

Modify `applications/home-automation/zigbee2mqtt/helmfile.yaml.gotmpl`:

```yaml
environments:
  default:
    values:
      - zigbee2mqtt:
          config:
            advanced:
              network_key: {{ fetchSecretValue "ref+vault://kv/home-automation/zigbee2mqtt#network-key" }}
            mqtt:
              user: {{ fetchSecretValue "ref+vault://kv/home-automation/zigbee2mqtt#mqtt-username" }}
              password: {{ fetchSecretValue "ref+vault://kv/home-automation/zigbee2mqtt#mqtt-password" }}

releases:
  - name: zigbee2mqtt
    namespace: home-automation
    chart: ./helm-chart
    values:
      - {{ .Values | toYaml | nindent 8 }}
```

3. **Test locally first**

```bash
source scripts/vault-dev-env.sh
export VAULT_TOKEN=<token>

# Template to verify secrets are fetched
helmfile -f applications/home-automation/zigbee2mqtt/helmfile.yaml.gotmpl template

# Check output shows actual values (redact in docs!)
```

4. **Remove ExternalSecret resource**

Move `applications/home-automation/zigbee2mqtt/resources/external-secret.yaml` to backup:

```bash
mv applications/home-automation/zigbee2mqtt/resources/external-secret.yaml \
   applications/home-automation/zigbee2mqtt/resources/external-secret.yaml.backup
```

5. **Commit and push**

```bash
git add applications/home-automation/zigbee2mqtt/
git commit -m "Migrate zigbee2mqtt secrets from External Secrets to Vals"
git push
```

6. **Monitor ArgoCD sync**

```bash
argocd app sync home-automation-zigbee2mqtt
argocd app wait home-automation-zigbee2mqtt --health
```

7. **Verify application health**

```bash
kubectl get pods -n home-automation -l app=zigbee2mqtt
kubectl logs -n home-automation -l app=zigbee2mqtt --tail=50
```

#### Deliverables

- [ ] Secrets added to Vault
- [ ] Helmfile updated with Vals references
- [ ] ExternalSecret removed/backed up
- [ ] Application synced and healthy

#### Success Criteria

- Application pod restarts and connects to MQTT successfully
- Zigbee network key loaded correctly
- No secrets visible in Git (only refs)
- ArgoCD shows healthy sync status

#### Rollback Plan

If migration fails:

```bash
# 1. Restore ExternalSecret
git revert HEAD
git push

# 2. ArgoCD will sync back to External Secrets
argocd app sync home-automation-zigbee2mqtt

# 3. Verify app recovers
kubectl get pods -n home-automation -l app=zigbee2mqtt
```

---

### Phase 5: Documentation and Guidelines (30 minutes)

**Objective**: Create clear documentation for team on when/how to use Vals.

#### Steps

1. **Create decision tree document**

Create `docs/SECRET-INJECTION-GUIDE.md`:

```markdown
# Secret Injection Decision Guide

## When to Use Which Method

### Use Vals (Helmfile + fetchSecretValue)

✅ **Use when:**
- Secret is app-specific (not shared)
- Secret is templated into config file
- Secret is relatively static (monthly updates)
- You control the Helmfile

❌ **Don't use when:**
- Secret is shared by 5+ applications
- Secret needs rotation without redeployment
- Legacy app expects K8s Secret object
- Secret updates daily/hourly

**Examples:**
- Zigbee2MQTT network key
- App-specific API tokens
- Application configuration with embedded secrets

### Use External Secrets Operator

✅ **Use when:**
- Secret is shared across multiple apps
- Secret needs automatic rotation
- Legacy app reads from K8s Secret
- Secret updates frequently

❌ **Don't use when:**
- Single app uses the secret
- Secret is templated into config
- Deploy-time fetch is acceptable

**Examples:**
- MQTT credentials (used by many apps)
- Database passwords
- Shared API keys

### Hybrid Approach (Recommended)

Many apps benefit from both:

```yaml
# helmfile.yaml.gotmpl - App-specific secret via Vals
environments:
  default:
    values:
      - appSecret: {{ fetchSecretValue "ref+vault://kv/realm/app#app-key" }}

# resources/external-secret.yaml - Shared MQTT creds
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: mqtt-creds
spec:
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: mosquitto-credentials
  data:
    - secretKey: username
      remoteRef:
        key: home-automation/mosquitto
        property: username
```

## Migration Checklist

- [ ] Identify secret type (app-specific vs shared)
- [ ] Add secret to Vault at `kv/<realm>/<app>`
- [ ] Update Helmfile with `fetchSecretValue` refs
- [ ] Test locally with port-forward
- [ ] Remove ExternalSecret (if applicable)
- [ ] Commit and push
- [ ] Monitor ArgoCD sync
- [ ] Verify application health
- [ ] Update application README
```

2. **Update main README**

Add section to `CLAUDE.md`:

```markdown
### Secret Injection Patterns

**Vals (Deploy-time):**
```yaml
# helmfile.yaml.gotmpl
environments:
  default:
    values:
      - secret: {{ fetchSecretValue "ref+vault://kv/realm/app#key" }}
```

**External Secrets (Runtime):**
```yaml
# resources/external-secret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
spec:
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  data:
    - secretKey: key
      remoteRef:
        key: realm/app
        property: key
```

See `docs/SECRET-INJECTION-GUIDE.md` for decision criteria.
```

3. **Create troubleshooting guide**

Add to `infrastructure/security/vault/README.md`:

```markdown
## Troubleshooting Vals Integration

### Local Development Issues

**Problem**: `fetchSecretValue` returns "ref+vault://..." literally

**Solution**:
```bash
# Verify VAULT_ADDR is set
echo $VAULT_ADDR

# Verify VAULT_TOKEN is set
echo $VAULT_TOKEN | head -c 10

# Test Vault connectivity
curl -H "X-Vault-Token: $VAULT_TOKEN" $VAULT_ADDR/v1/kv/data/test/vals-test

# Test vals directly
vals eval "ref+vault://kv/test/vals-test#foo"
```

**Problem**: "permission denied" error

**Solution**: Check Vault token has read access:
```bash
kubectl exec -n security vault-0 -- sh -c '
export VAULT_TOKEN="<your-token>"
vault token lookup
'
```

### ArgoCD Issues

**Problem**: ArgoCD sync fails with Vault auth error

**Solution**:
```bash
# Check repo-server can reach Vault
kubectl exec -n argocd deploy/argocd-repo-server -- \
  curl -s http://vault.security:8200/v1/sys/health

# Check Kubernetes auth from repo-server
kubectl exec -n argocd deploy/argocd-repo-server -- sh -c '
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s --request POST \
  --data "{\"jwt\": \"$SA_TOKEN\", \"role\": \"argocd\"}" \
  http://vault.security:8200/v1/auth/kubernetes/login | jq
'

# Check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100
```

**Problem**: Secret not found in Vault

**Solution**: Verify secret exists and path is correct:
```bash
# List secrets in path
kubectl exec -n security vault-0 -- sh -c '
export VAULT_TOKEN="<root-token>"
vault kv list kv/home-automation
'

# Read specific secret
kubectl exec -n security vault-0 -- sh -c '
export VAULT_TOKEN="<root-token>"
vault kv get kv/home-automation/zigbee2mqtt
'
```
```

#### Deliverables

- [ ] Decision guide created
- [ ] CLAUDE.md updated
- [ ] Troubleshooting guide added to README

---

## Testing Strategy

### Unit Tests (Per-Phase)

#### Phase 1: Kubernetes Auth
```bash
# Test 1: Verify auth method enabled
kubectl exec -n security vault-0 -- vault auth list | grep kubernetes

# Test 2: Verify role exists
kubectl exec -n security vault-0 -- sh -c '
export VAULT_TOKEN="<root-token>"
vault read auth/kubernetes/role/argocd
'

# Test 3: Authenticate from ArgoCD namespace
kubectl run -n argocd vault-auth-test --rm -it --image=hashicorp/vault:latest --restart=Never -- sh -c '
export VAULT_ADDR=http://vault.security:8200
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
vault write auth/kubernetes/login role=argocd jwt=$SA_TOKEN
'
```

#### Phase 2: Local Development
```bash
# Test 1: Port-forward works
source scripts/vault-dev-env.sh
curl -s $VAULT_ADDR/v1/sys/health | jq '.sealed'

# Test 2: Vals can fetch secrets
export VAULT_TOKEN=<token>
vals eval "ref+vault://kv/test/vals-test#foo"

# Test 3: Helmfile templates correctly
helmfile -f infrastructure/security/vault/examples/test-vals.yaml template | grep "secret-value"
```

#### Phase 3: ArgoCD Integration
```bash
# Test 1: VAULT_ADDR set in repo-server
kubectl get deploy argocd-repo-server -n argocd -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="VAULT_ADDR")].value}'

# Test 2: Repo-server can reach Vault
kubectl exec -n argocd deploy/argocd-repo-server -- curl -s http://vault.security:8200/v1/sys/health

# Test 3: ArgoCD syncs test app
argocd app sync test-vals-integration
argocd app get test-vals-integration | grep "Sync Status:"
```

### Integration Tests

#### End-to-End Test: Local to Production

1. **Create test secret in Vault**
   ```bash
   kubectl exec -n security vault-0 -- sh -c '
   export VAULT_TOKEN="<root-token>"
   vault kv put kv/test/e2e-test \
     local="test-from-local" \
     argocd="test-from-argocd"
   '
   ```

2. **Create test Helmfile**
   ```yaml
   # test-e2e.yaml
   environments:
     default:
       values:
         - localSecret: {{ fetchSecretValue "ref+vault://kv/test/e2e-test#local" }}
         - argocdSecret: {{ fetchSecretValue "ref+vault://kv/test/e2e-test#argocd" }}

   releases:
     - name: vals-e2e-test
       namespace: default
       chart: stable/raw
       values:
         - resources:
             - apiVersion: v1
               kind: ConfigMap
               metadata:
                 name: vals-e2e-test
               data:
                 local: {{ .Values.localSecret | quote }}
                 argocd: {{ .Values.argocdSecret | quote }}
   ```

3. **Test locally**
   ```bash
   source scripts/vault-dev-env.sh
   export VAULT_TOKEN=<token>
   helmfile -f test-e2e.yaml template | grep -A2 "data:"
   ```
   Expected: Shows both secret values

4. **Test via ArgoCD**
   ```bash
   # Create Application pointing to test-e2e.yaml
   argocd app create vals-e2e-test \
     --repo https://github.com/quidome/gitops-lab.git \
     --path infrastructure/security/vault/examples \
     --dest-server https://kubernetes.default.svc \
     --dest-namespace default \
     --sync-policy automated

   argocd app wait vals-e2e-test --health

   # Verify ConfigMap has secret values
   kubectl get configmap vals-e2e-test -o yaml
   ```
   Expected: ConfigMap contains both secret values

5. **Cleanup**
   ```bash
   argocd app delete vals-e2e-test
   kubectl delete configmap vals-e2e-test
   kubectl exec -n security vault-0 -- sh -c '
   export VAULT_TOKEN="<root-token>"
   vault kv delete kv/test/e2e-test
   '
   ```

### Regression Tests

After migration, verify existing External Secrets still work:

```bash
# Test ExternalSecret for MQTT credentials
kubectl get externalsecret -n home-automation mosquitto-credentials -o yaml

# Verify generated secret exists
kubectl get secret -n home-automation mosquitto-credentials -o yaml

# Check External Secrets Operator logs
kubectl logs -n security -l app.kubernetes.io/name=external-secrets --tail=50
```

---

## Rollback Plan

### Phase-by-Phase Rollback

#### Phase 1 Rollback: Remove Kubernetes Auth
```bash
kubectl exec -n security vault-0 -- sh -c '
export VAULT_TOKEN="<root-token>"
vault auth disable kubernetes
vault policy delete argocd-reader
'
```

#### Phase 2 Rollback: N/A
Local scripts don't affect production.

#### Phase 3 Rollback: Remove ArgoCD Vault Integration
```bash
# Remove VAULT_ADDR env var
kubectl patch deployment argocd-repo-server -n argocd --type=json -p='[
  {
    "op": "remove",
    "path": "/spec/template/spec/containers/0/env",
    "value": {"name": "VAULT_ADDR"}
  }
]'

# Or revert kustomization changes
cd infrastructure-legacy/controllers/argocd
git revert <commit-hash>
kubectl kustomize --enable-helm . | kubectl apply -f -
```

#### Phase 4 Rollback: Restore External Secrets
```bash
# Restore ExternalSecret resource
git revert <migration-commit>
git push

# ArgoCD will sync and recreate ExternalSecret
argocd app sync <app-name>
```

### Emergency Rollback: Full Revert

If catastrophic failure, disable Vals and revert all changes:

```bash
# 1. Disable Kubernetes auth
kubectl exec -n security vault-0 -- sh -c '
export VAULT_TOKEN="<root-token>"
vault auth disable kubernetes
'

# 2. Revert ArgoCD changes
cd infrastructure-legacy/controllers/argocd
git revert <first-vals-commit>..<last-vals-commit>
kubectl kustomize --enable-helm . | kubectl apply -f -

# 3. Revert all application changes
git revert <migration-commit-range>
git push

# 4. Force sync all applications
argocd app sync --selector argocd.argoproj.io/instance=<app-pattern>

# 5. Monitor for recovery
watch kubectl get pods --all-namespaces
```

### Rollback Success Criteria

- [ ] All applications running and healthy
- [ ] External Secrets syncing successfully
- [ ] No Vault-related errors in logs
- [ ] ArgoCD syncs complete without errors

---

## Maintenance

### Regular Tasks

#### Daily
- Monitor Vault seal status
  ```bash
  kubectl exec -n security vault-0 -- vault status
  ```

#### Weekly
- Review Vault audit logs (if enabled)
- Check secret access patterns
- Rotate developer tokens (if using token auth)

#### Monthly
- Review and update ArgoCD Kubernetes auth role TTL
- Audit vault policies
- Update documentation with lessons learned

### Secret Rotation

#### For Vals-managed secrets:
1. Update secret in Vault (UI or CLI)
2. Trigger ArgoCD sync (or wait for auto-sync)
3. Pods will restart with new secret values

#### For External Secrets-managed secrets:
1. Update secret in Vault
2. External Secrets Operator auto-syncs based on `refreshInterval`
3. Pods may need restart depending on mount type

### Monitoring

**Vault health:**
```bash
# Check seal status
kubectl exec -n security vault-0 -- vault status

# Check Kubernetes auth
kubectl exec -n security vault-0 -- sh -c '
export VAULT_TOKEN="<root-token>"
vault list auth/kubernetes/role
'
```

**ArgoCD integration:**
```bash
# Check repo-server logs for Vault errors
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100 | grep -i vault

# List applications using Vals
argocd app list -o json | jq '.[] | select(.spec.source.plugin.name == "helmfile")'
```

**Secret usage:**
```bash
# List secrets in Vault
kubectl exec -n security vault-0 -- sh -c '
export VAULT_TOKEN="<root-token>"
vault kv list -format=json kv/ | jq
'

# Check External Secrets status
kubectl get externalsecret --all-namespaces
kubectl get clustersecretstore
```

---

## Appendices

### Appendix A: Vault Policy Templates

**Read-only policy (for ArgoCD/developers):**
```hcl
# Policy: argocd-reader
path "kv/data/*" {
  capabilities = ["read"]
}

path "kv/metadata/*" {
  capabilities = ["list", "read"]
}
```

**Admin policy (for secret management):**
```hcl
# Policy: secret-admin
path "kv/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
```

**Application-specific policy:**
```hcl
# Policy: home-automation-reader
path "kv/data/home-automation/*" {
  capabilities = ["read"]
}

path "kv/metadata/home-automation/*" {
  capabilities = ["list", "read"]
}
```

### Appendix B: Vals Reference Syntax

**Basic reference:**
```yaml
secret: {{ fetchSecretValue "ref+vault://kv/path/to/secret#key" }}
```

**With explicit Vault address:**
```yaml
secret: {{ fetchSecretValue "ref+vault://http://vault.security:8200/kv/path#key" }}
```

**Multiple keys from same secret:**
```yaml
user: {{ fetchSecretValue "ref+vault://kv/app/creds#username" }}
pass: {{ fetchSecretValue "ref+vault://kv/app/creds#password" }}
```

**Default value if secret missing:**
```yaml
# Not directly supported by vals, use Helmfile conditionals:
secret: {{ fetchSecretValue "ref+vault://kv/path#key" | default "fallback" }}
```

### Appendix C: ArgoCD Helmfile Plugin Configuration

Expected plugin configuration in ArgoCD:

```yaml
# configManagementPlugins in argocd-cm ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  configManagementPlugins: |
    - name: helmfile
      init:
        command: ["/bin/sh", "-c"]
        args:
          - |
            helmfile init --force
      generate:
        command: ["/bin/sh", "-c"]
        args:
          - |
            helmfile template --include-crds
```

Vals is built into Helmfile, no additional configuration needed.

### Appendix D: Migration Tracking

**Migration Progress Tracker:**

| Application | Current Method | Target Method | Status | Date | Notes |
|-------------|---------------|---------------|--------|------|-------|
| mosquitto | External Secrets | External Secrets | ✅ Keep | - | Shared by 5+ apps |
| zigbee2mqtt | External Secrets | Vals | ⏸️ Pending | - | App-specific secrets |
| syncthing | External Secrets | Hybrid | ⏸️ Pending | - | Mix of shared/app-specific |
| saic-mqtt-gateway | External Secrets | Vals | ✅ **Completed** | 2026-02-13 | Migrated to Vals successfully |
| external-dns | External Secrets | External Secrets | ✅ Keep | - | Shared infrastructure secret |

---

## Sign-off

### Phase Completion Checklist

- [x] **Phase 0**: Prerequisites verified
- [x] **Phase 1**: Token-based auth configured (simpler than Kubernetes auth)
- [x] **Phase 2**: Local development working
- [x] **Phase 3**: ArgoCD integration complete
- [x] **Phase 4**: First application migrated (saic-mqtt-gateway)
- [x] **Phase 5**: Documentation complete

### Stakeholder Approval

- [ ] Infrastructure lead reviewed
- [ ] Security team approved auth configuration
- [ ] Development team trained on local workflow
- [ ] Documentation reviewed and published

### Success Metrics

After implementation:
- ✅ Developers can use `helmfile apply` locally with Vault secrets
- ✅ ArgoCD syncs applications using Vals without errors
- ✅ At least one application migrated from External Secrets to Vals
- ✅ External Secrets continues working for shared secrets
- ✅ No secrets stored in plaintext in Git

---

## Implementation Notes (2026-02-13)

### What Was Actually Implemented

**Deviations from original spec:**
1. **Used token-based auth instead of Kubernetes auth** - Simpler setup, good enough for home lab
2. **No auto-unseal** - Manual unseal accepted as operational procedure
3. **Hybrid approach confirmed** - Vals for app-specific secrets, External Secrets for infrastructure

### Key Lessons Learned

#### Critical: Helmfile-Plugin Container Requires VAULT Env Vars

**Problem:** ArgoCD sync failed with `dial tcp 127.0.0.1:8200: connect: connection refused`

**Root cause:** Vals runs in the `helmfile-plugin` sidecar container (index 2), not the main `repo-server` container. Environment variables must be set on BOTH containers.

**Solution:**
```bash
# Container 0: repo-server (optional, for reference)
kubectl patch deployment argocd-repo-server -n argocd --type=json -p='[...]'

# Container 2: helmfile-plugin (CRITICAL - Vals runs here!)
kubectl patch deployment argocd-repo-server -n argocd --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/2/env",
    "value": [
      {"name": "VAULT_ADDR", "value": "http://vault.security:8200"},
      {"name": "VAULT_TOKEN", "valueFrom": {"secretKeyRef": {"name": "vault-token", "key": "token"}}}
    ]
  }
]'
```

**Documentation updated:** `infrastructure/security/vault/VALS-SETUP.md` Section 2b

#### Secret Object vs Direct Env Vars

**Decision:** Use Secret object pattern (Option 1 from spec)

**Rationale:**
- Secrets not visible in `kubectl describe pod`
- Better RBAC (can grant `get pods` without exposing secrets)
- Kubernetes best practice
- No real downside (one extra template file)

**Implementation:**
- `helmfile.yaml.gotmpl`: Vals fetches secrets, passes to chart via values
- `helm-chart/templates/secret.yaml`: Creates K8s Secret from values
- `helm-chart/templates/deployment.yaml`: Uses `envFrom.secretRef` (unchanged)

#### Refreshing Secrets

**With Vals (deploy-time):**
```bash
argocd app sync <app-name>  # Fetches latest from Vault
```

**With External Secrets (runtime):**
- Auto-syncs every 1 hour
- No manual intervention needed

**Conclusion:** Vals best for static, app-specific secrets. External Secrets best for shared, frequently updated secrets.

### Migration Results

**Migrated:** saic-mqtt-gateway (2026-02-13)
- 5 secrets: SAIC_USER, SAIC_PASSWORD, MQTT_USER, MQTT_PASSWORD, ABRP_USER_TOKEN
- Method: Vals via helmfile.yaml.gotmpl
- Status: ✅ Working in production

**Remaining on External Secrets:**
- mosquitto (shared secret)
- Infrastructure secrets (cert-manager, external-dns, democratic-csi)
- Intentionally kept for runtime sync benefit

### Success Metrics Achieved

- ✅ Developers can use `helmfile apply` locally with Vault secrets
- ✅ ArgoCD syncs applications using Vals without errors (after helmfile-plugin fix)
- ✅ saic-mqtt-gateway migrated from External Secrets to Vals
- ✅ External Secrets continues working for shared secrets (hybrid approach)
- ✅ No secrets stored in plaintext in Git

### Next Steps

1. Monitor saic-mqtt-gateway for secret rotation workflow
2. Consider migrating zigbee2mqtt (if/when moved to new helmfile structure)
3. Keep infrastructure secrets on External Secrets (runtime sync more resilient)

---

**Document Version**: 1.1
**Last Updated**: 2026-02-13
**Status**: Implementation Complete
**Next Review**: After 30 days of production use
