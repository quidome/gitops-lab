# Pocket ID

Pocket ID is the internal OIDC provider for the homelab.

## Deployment

- **Namespace:** `security`
- **URL:** `https://id.quido.me`
- **Gateway:** `gateway-internal`
- **Image:** `ghcr.io/pocket-id/pocket-id:v2.14.0`
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

Generate the value outside Git with a secure random generator and store it in
Vault without a trailing newline. Do not print it in logs, commit it, or rotate
it casually. Losing or changing this key can make encrypted Pocket ID data
unrecoverable.

Helmfile Vals fetches the key during Argo CD rendering and renders the Kubernetes Secret `pocket-id-secrets`. The workload reads the key from a mounted file using `ENCRYPTION_KEY_FILE`. The key is never stored in Git.

## First administrator enrollment

Complete this once after the Pod is healthy and `https://id.quido.me` resolves
through internal DNS:

1. Open the URL over HTTPS and complete Pocket ID's first administrator
   enrollment.
2. Enroll the primary passkey, then enroll a second recovery passkey on a
   separate trusted device using Pocket ID's normal account settings.
3. Sign out and sign back in with each enrolled passkey.
4. Record the non-sensitive result and the location of the recovery devices;
   never record passkeys, recovery codes, or session tokens in Git.
5. Create OIDC clients only after administrator login and recovery have been
   verified.

Client secrets must be stored in Vault using the existing application secret
convention. Never place them in Helm values committed to Git.

## Initial OIDC clients

Create clients manually in Pocket ID only when the owning integration is ready.
Do not create a client secret until its Vault destination exists.

| Client | Redirect URI | Post-logout redirect | Scopes | Group claim |
| --- | --- | --- | --- | --- |
| Argo CD | `https://argocd.quido.me/auth/callback` | `https://argocd.quido.me` | `openid profile email groups` | yes |
| Grafana | `https://grafana.quido.me/login/generic_oauth` | `https://grafana.quido.me/login` | `openid profile email` | no |
| Vault | `https://vault.quido.me/ui/vault/auth/oidc/oidc/callback` | none; Vault UI does not configure RP-initiated logout | `openid profile email groups` | yes |
| FreshRSS (deferred) | `https://rss.quido.me/i/oidc/` | not applicable until enabled | `openid profile email` | no |
| Karma proof of concept | `https://alerts-sso.quido.me/oauth2/callback` | `https://alerts-sso.quido.me/` for an explicit `rd` logout | `openid profile email groups` | yes (`argocd-admins`, `argocd-readonly`) |

The Vault callback must be confirmed against the actual Vault OIDC auth mount
before creating the client. FreshRSS remains deferred because native OIDC
would replace its local UI authentication; see its compatibility decision.
The Karma client is created only after the temporary proxy route and Vault
secret destination are prepared.

## Client rotation and revocation

1. Create a replacement Pocket ID client while retaining the existing client.
2. Store its ID and secret in the owning Vault path under replacement keys or
   the documented key names during a controlled cutover.
3. Update the owning Helmfile and sync through Argo CD; test login, logout,
   fallback, and application behavior.
4. Remove the old secret only after the replacement is verified. Revoke the
   old Pocket ID client last, then remove its redirect URI.
5. For an emergency rollback, restore the previous Vault value and Helmfile
   configuration before revoking the old client.

## Backup and restore

Back up all of the following:

1. The Pocket ID persistent volume, including the SQLite database and uploaded
   data.
2. The permanent Pocket ID encryption key from `kv/security/pocket-id`.
3. Pocket ID's supported export, where practical. Export/import is experimental
   and is an additional recovery mechanism, not a replacement for the volume
   snapshot.
4. OIDC client inventory and redirect URI documentation without exporting
   client secrets into Git.

Use the existing TrueNAS snapshot and replication process for the iSCSI volume.
The recommended policy is daily snapshots retained for 30 days, replicated to
the existing secure backup location, with a weekly backup-integrity review.
Adjust the schedule only through the homelab's storage backup policy.

For a restore test, clone or restore the snapshot into an isolated maintenance
namespace or maintenance window, restore the **same** encryption key before
starting Pocket ID, and verify the database, uploaded data, WebAuthn origin,
administrator login, and at least one OIDC discovery request. Do not rotate the
production key for a test. Record the date, snapshot, result, and any issues;
perform the test at least quarterly. A database backup without its matching
key is not sufficient and can make encrypted data unrecoverable.

The supported CLI export writes an archive to a selected path or stdout. In
an approved maintenance procedure, an operator can stream it from the running
container to a secure location (never the repository):

```bash
kubectl exec -n security deploy/pocket-id -- ./pocket-id export --path - \
  > /secure-backups/pocket-id-$(date +%Y%m%d).zip
```

Import is destructive and must be done only after a fresh volume snapshot, with
Pocket ID stopped and the matching encryption key restored. In a maintenance
container using the same image and PVC, use the documented equivalent:

```bash
./pocket-id import --yes --path - < /secure-backups/pocket-id-export.zip
```

The export/import feature is experimental; verify the restored login and data
before considering it a successful backup.

## Recovery when Pocket ID is unavailable

If the Pocket ID route, internal DNS, Gateway, or Pod is unavailable, do not
attempt to recover the cluster through Pocket ID. Use the application's
retained local or emergency path, repair Pocket ID independently, and only
re-enable dependent OIDC clients after its HTTPS origin and login are healthy.

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
