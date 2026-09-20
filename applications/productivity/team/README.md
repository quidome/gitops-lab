# Team coordinator deployment

The Team coordinator is deployed to the `productivity` namespace through the
repository ApplicationSet and Helmfile plugin.

## Deployment contract

- Source repository: https://github.com/quidome/team
- Verified source revision: `ec35e78` (`feat(navigation): add icon-based active section navigation`)
- Runtime image: `ghcr.io/quidome/team@sha256:852068913108c2b7b252c0cf693813a8b1a531fdb5932f0b017db058a120ece2`
- Migration image: `ghcr.io/quidome/team@sha256:beb51b0d8b383c1293a352eedd114433599800cc4e3b19d1c8ad504c1c0c092e`
- PostgreSQL chart: local `postgresql-chart`
- PostgreSQL image: `docker.io/library/postgres@sha256:3c5c8892d184f738f4fe282d14ddaa613a38f00f4189d2d94725ebe6f2909ddb` (official `postgres:16-alpine`)
- Service: `team.productivity.svc.cluster.local:3000`
- PostgreSQL service: `team-postgresql.productivity.svc.cluster.local:5432`
- PostgreSQL database/role: `team`
- Public origin: `https://team.quido.me`
- Gateway: `networking/gateway-internal`

The runtime digest and migration digest are separate OCI indexes published from
the same source revision. The Secret is applied at sync wave `-2`, then the
migration runs as an Argo CD `Sync` hook at wave `-1`; it must complete before
the Deployment at wave `0` is rolled out. Failed migration hooks remain for
inspection and cause the sync to fail; a later sync removes the old hook before
creating a new one.

## Runtime configuration

Helmfile retrieves deployment secrets from Vault at:

```text
kv/productivity/team
```

Required keys:

- `DATABASE_URL` - complete PostgreSQL URL; use
  `postgresql://team:<password>@team-postgresql.productivity.svc.cluster.local:5432/team`.
  The password must be URL-encoded; generating it as hex avoids encoding issues.
- `POSTGRES_PASSWORD` - the same password supplied to the PostgreSQL
  StatefulSet. Keep this synchronized with `DATABASE_URL`.
- `OIDC_ISSUER_URL` - Pocket ID issuer URL.
- `OIDC_CLIENT_ID` - Pocket ID client identifier.
- `OIDC_CLIENT_SECRET` - Pocket ID client secret.
- `SESSION_SECRET` - random value of at least 32 characters.

Reviewable runtime defaults are defined in `helm-chart/values.yaml`; the deployed
OIDC issuer URL and client identifier are supplied from Vault:

- `ORIGIN=https://team.quido.me`
- `SESSION_TTL_SECONDS=28800`
- `DEV_AUTH_BYPASS=false`

The runtime chart stores the three sensitive Vault-provided values in a
Kubernetes Secret as base64-encoded data. The runtime consumes all three via
`valueFrom`, while the migration Job consumes only `DATABASE_URL`. `OIDC_ISSUER_URL` and `OIDC_CLIENT_ID` are rendered as direct runtime environment
variables. The PostgreSQL chart stores
`POSTGRES_PASSWORD` in its own Secret. Vault-backed changes alter the runtime
checksum and trigger a rollout.

## Pocket ID registration

Create the Pocket ID client and store its exact client identifier in
`OIDC_CLIENT_ID`. Configure it with:

- Redirect URI: `https://team.quido.me/auth/callback`
- Scope: `openid`
- Issuer: `https://id.quido.me`

Store the issuer URL, client identifier, and generated client secret at
`kv/productivity/team` under `OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, and
`OIDC_CLIENT_SECRET`. Do not record the client secret in Git or operational
notes.

## PostgreSQL ownership and recovery boundary

The Helmfile provisions a standalone PostgreSQL StatefulSet named
`team-postgresql` with a 10Gi `truenas-iscsi` ReadWriteOnce volume, a ClusterIP
service, and a NetworkPolicy allowing only the Team runtime and migration pods
to connect. The database role and database are both `team`.

Create these Vault keys before the first sync:

```text
kv/productivity/team
  POSTGRES_PASSWORD=<URL-safe generated password>
  DATABASE_URL=postgresql://team:<same-password>@team-postgresql.productivity.svc.cluster.local:5432/team
```

Backups remain owned by the homelab storage/backup process. No in-chart logical-dump helper is configured because a dump on a local PVC is
not an off-cluster, restore-verified backup. Configure and verify TrueNAS snapshots,
replication, retention, and isolated restore before production use.

Migrations are forward-only from the application's perspective. Rolling back
the runtime image is safe only when the previous image is compatible with the
already-applied schema. Do not attempt an automatic schema downgrade. For an
irreversible migration, stop the rollout and restore the database from a
verified backup according to the database owner's recovery procedure before
starting a compatible application image.

## Secret rotation

1. Update the relevant value in `kv/productivity/team`.
2. Trigger an Argo CD sync so Helmfile/Vals renders the new value.
3. Verify the migration hook and runtime health before closing the change.

`POSTGRES_PASSWORD` initializes the PostgreSQL role; changing the Kubernetes
Secret alone does not change an already-initialized database role. Rotate the
database credential during a maintenance window: change the PostgreSQL role
password, update `POSTGRES_PASSWORD` and `DATABASE_URL` together in Vault, then
sync and verify the migration hook and readiness. Retain the PostgreSQL volume
through the change. Rotating `OIDC_CLIENT_SECRET` requires the replacement
Pocket ID client to be registered before sync. Rotating `SESSION_SECRET`
invalidates existing coordinator sessions; users must sign in again.

## Validation

Run chart checks from the repository root before GitOps promotion:

```bash
helm lint applications/productivity/team/postgresql-chart
helm template team-postgresql applications/productivity/team/postgresql-chart --namespace productivity
helm lint applications/productivity/team/helm-chart
helm template team applications/productivity/team/helm-chart --namespace productivity
helm lint applications/productivity/team/resources
helm template team-resources applications/productivity/team/resources --namespace productivity
helmfile -f applications/productivity/team/helmfile.yaml.gotmpl lint
helmfile -f applications/productivity/team/helmfile.yaml.gotmpl template
```

Do not use `helm install`, `helm upgrade`, or direct `kubectl apply`; promote
through Argo CD after review.
