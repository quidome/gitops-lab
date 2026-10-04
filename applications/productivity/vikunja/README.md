# Vikunja

Self-hosted task manager for family lists and software projects, deployed to
the `productivity` namespace through the repository ApplicationSet and
Helmfile plugin.

## Deployment contract

- Upstream chart: `oci://ghcr.io/go-vikunja/helm-chart/vikunja` (wraps the
  bjw-s common library chart v1.5.1)
- Runtime image: `vikunja/vikunja:2.7.0`
- PostgreSQL chart: local `postgresql-chart` (copy of the Team coordinator one)
- Service: `vikunja.productivity.svc.cluster.local:3456`
- PostgreSQL service: `vikunja-postgresql.productivity.svc.cluster.local:5432`
- PostgreSQL database/role: `vikunja`
- Files volume: `vikunja-data`, 5Gi `truenas-iscsi`, mounted at
  `/app/vikunja/files` (attachments, project backgrounds)
- Public origin: `https://tasks.quido.me`
- Gateway: `networking/gateway-internal`

Non-secret configuration lives in `values.yaml` as `config.yml`, mounted at
`/etc/vikunja/config.yml`. Secret values are set as `VIKUNJA_*` environment
variables from the `vikunja-secret` Secret; Vikunja merges them on top of the
config file. Local login and self-registration are off: users sign in through
Pocket ID, and an account is created on first sign-in.

## Runtime configuration

Helmfile retrieves deployment secrets from Vault at:

```text
kv/productivity/vikunja
```

Required keys:

- `POSTGRES_PASSWORD` - password for the `vikunja` PostgreSQL role. Used by both
  the PostgreSQL StatefulSet and Vikunja.
- `SERVICE_SECRET` - random value used to sign login tokens
  (`openssl rand -hex 32`).
- `OIDC_CLIENT_ID` - Pocket ID client identifier.
- `OIDC_CLIENT_SECRET` - Pocket ID client secret.

## Pocket ID registration

Create a Pocket ID client with:

- Callback URL: `https://tasks.quido.me/auth/openid/pocketid`
- Scopes: `openid profile email`

Store the client identifier and secret at `kv/productivity/vikunja`.

## Sharing

Create a team in Vikunja (for example "Family") and share projects with it.
Software projects can stay personal or be shared with a separate team.

## Backups

The PostgreSQL volume and the files volume both use the Retain policy. Off-cluster
backups remain owned by the homelab storage/backup process (TrueNAS snapshots
and replication).

## Validation

```bash
helm lint applications/productivity/vikunja/postgresql-chart
helm lint applications/productivity/vikunja/resources
helmfile -f applications/productivity/vikunja/helmfile.yaml.gotmpl template
```
