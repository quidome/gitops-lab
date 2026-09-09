# Pocket ID OIDC setup

Vault authentication configuration is stored in Vault's data volume, not in the Helm chart. It is intentionally bootstrapped manually: a GitOps reconciliation job would need a Vault root or management token in Kubernetes.

Do not commit or inject a root token, OIDC client secret, or generated user token.

## Prerequisites

Create a confidential `Vault` OIDC client in Pocket ID with:

- callback URL: `https://vault.quido.me/ui/vault/auth/oidc/oidc/callback`
- scopes: `openid profile email groups`
- allowed groups: `vault-admins` and `vault-readonly`

Store the generated values in Vault:

```text
kv/security/vault
oidc-client-id
oidc-client-secret
```

## One-time bootstrap

Use the local management token from `gopass`; it is never written to disk or printed. The following helper passes it to the Vault pod over standard input:

```bash
VAULT_ADMIN_TOKEN="$(gopass show personal/vault/prod/root-token)"

vault_admin() {
  printf '%s\n' "$VAULT_ADMIN_TOKEN" |
    kubectl exec -i -n security vault-0 -- sh -c '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN
      exec vault "$@"
    ' sh "$@"
}
```

Run the following only on a Vault instance where `oidc/` is not already enabled:

```bash
CLIENT_ID="$(vault_admin kv get -field=oidc-client-id kv/security/vault)"
CLIENT_SECRET="$(vault_admin kv get -field=oidc-client-secret kv/security/vault)"

vault_admin auth enable oidc
vault_admin write auth/oidc/config \
  oidc_discovery_url="https://id.quido.me" \
  oidc_client_id="$CLIENT_ID" \
  oidc_client_secret="$CLIENT_SECRET" \
  default_role="pocket-id"
vault_admin write auth/oidc/role/pocket-id \
  bound_audiences="$CLIENT_ID" \
  user_claim="sub" \
  groups_claim="groups" \
  allowed_redirect_uris="https://vault.quido.me/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
  oidc_scopes="openid,profile,email,groups"
```

Create the read-only policy:

```bash
cat <<'EOF' | vault_admin policy write vault-readonly -
path "kv/data/*" {
  capabilities = ["read"]
}

path "kv/metadata/*" {
  capabilities = ["list", "read"]
}

path "sys/internal/ui/mounts" {
  capabilities = ["read"]
}

path "sys/internal/ui/mounts/*" {
  capabilities = ["read"]
}

path "sys/internal/ui/resultant-acl" {
  capabilities = ["read"]
}
EOF
```

Create external identity groups and aliases for the `groups` OIDC claim:

```bash
OIDC_ACCESSOR="$(vault_admin read -field=accessor sys/auth/oidc)"
ADMIN_GROUP_ID="$(vault_admin write -field=id identity/group name=vault-admins type=external policies=admin)"
READONLY_GROUP_ID="$(vault_admin write -field=id identity/group name=vault-readonly type=external policies=vault-readonly)"

vault_admin write identity/group-alias \
  name=vault-admins \
  mount_accessor="$OIDC_ACCESSOR" \
  canonical_id="$ADMIN_GROUP_ID"
vault_admin write identity/group-alias \
  name=vault-readonly \
  mount_accessor="$OIDC_ACCESSOR" \
  canonical_id="$READONLY_GROUP_ID"
```

`vault-admins` intentionally uses the existing `admin` policy. Do not map an OIDC group to the root policy.

## Validation

1. Open `https://vault.quido.me` and choose the `OIDC` auth method.
2. Sign in through Pocket ID with a member of `vault-admins`.
3. Confirm the resulting token has the `admin` policy.
4. Sign in with a `vault-readonly` member and confirm KV reads and metadata listing work while writes are denied.
5. Verify `userpass`, AppRole, and root-token recovery access still work.

A Vault restart is not required after changing auth configuration.

## Recovery

If Pocket ID, DNS, or the Gateway is unavailable, use the existing `userpass` method or root token. Do not disable either until an alternative tested recovery procedure is documented.
