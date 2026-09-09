# Pocket ID

Pocket ID is the internal OIDC provider for the homelab.

## Deployment

- **Namespace:** `security`
- **URL:** `https://id.quido.me`
- **Gateway:** `gateway-internal`
- **Image:** `ghcr.io/pocket-id/pocket-id:v2.12.0`
- **Data:** SQLite under `/app/data` on `truenas-iscsi`
- **Secret source:** Vault through Helmfile Vals during Argo CD rendering

Pocket ID is intentionally exposed only through the internal Gateway. The wildcard certificate already covers `id.quido.me`; the HTTPRoute is also an input to the existing ExternalDNS configuration.

## Required Vault secret

Before the first GitOps sync, create the permanent encryption key in Vault at:

```text
kv/security/pocket-id
```

Required key:

```text
encryption-key
```

Generate the value outside Git with a secure random generator. Do not print it in logs, commit it, or rotate it casually. Losing or changing this key can make encrypted Pocket ID data unrecoverable.

Helmfile Vals fetches the key during Argo CD rendering and renders the Kubernetes Secret `pocket-id-secrets`. The workload reads the key from a mounted file using `ENCRYPTION_KEY_FILE`. The key is never stored in Git.

## First enrollment

1. Confirm the Pocket ID pod is healthy and `https://id.quido.me` resolves through the internal DNS service.
2. Open the URL using HTTPS and complete the first administrator enrollment.
3. Register at least one recovery passkey using the normal Pocket ID procedure.
4. Confirm the administrator can sign out and sign back in.
5. Create OIDC clients only after the Pocket ID administrator login has been verified.

Client secrets must be stored in Vault using the existing application secret convention. Never place them in Helm values committed to Git.

## Initial OIDC clients

The initial clients are created manually in Pocket ID and then configured in their owning components:

| Client | Redirect URI | Scopes |
| --- | --- | --- |
| Argo CD | `https://argocd.quido.me/auth/callback` | `openid profile email groups` |
| Grafana | `https://grafana.quido.me/login/generic_oauth` | `openid profile email` |
| Vault | `https://vault.quido.me/ui/vault/auth/oidc/oidc/callback` | `openid profile email groups` |
| FreshRSS | `https://rss.quido.me/i/oidc/` | `openid profile email` |
| Karma proof of concept | temporary internal hostname ending in `/oauth2/callback` | `openid profile email` |

The Vault callback must be confirmed against the actual Vault OIDC auth mount before creating the client. The FreshRSS callback must be confirmed against the deployed FreshRSS version before enabling it.

## Backup and restore

Back up all of the following:

1. The Pocket ID persistent volume, including the SQLite database and uploaded data.
2. The Pocket ID encryption key.
3. Pocket ID's supported data export, where practical.
4. OIDC client inventory and redirect URI documentation without exporting client secrets into Git.

Use the existing TrueNAS snapshot and replication process for the iSCSI volume. Perform a restore test in a safe environment or controlled maintenance window. Restore the encryption key before starting Pocket ID; a database backup without the matching key is not sufficient.

## Break-glass access

Pocket ID must not be required to recover the cluster:

- Recover Argo CD through its retained local administrator account and direct Kubernetes service or port-forward access.
- Recover Vault through userpass, root-token, unseal-key, and direct Kubernetes service or port-forward access.
- Keep the Kubernetes API and Argo CD GitOps control path independent of the Pocket ID route.

Do not disable these paths after OIDC is enabled.

## Validation

Render and validate locally before GitOps promotion:

```bash
helmfile -f infrastructure/security/pocket-id/helmfile.yaml.gotmpl lint
helmfile -f infrastructure/security/pocket-id/helmfile.yaml.gotmpl template
```

Inspect the rendered output for:

- `id.quido.me` using `gateway-internal`.
- `truenas-iscsi` storage and `Recreate` strategy.
- No plaintext encryption key or client secret.
- Correct `security` namespace.
- Explicit HTTPRoute backend defaults.
