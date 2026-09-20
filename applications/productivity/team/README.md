# Team coordinator deployment

The Team coordinator is deployed to the `productivity` namespace through the
repository ApplicationSet and Helmfile plugin.

## Deployment contract

- Source repository: https://github.com/quidome/team
- Verified source revision: `8936d2f` (`ci(container): build and publish images to ghcr`)
- Runtime image: `ghcr.io/quidome/team@sha256:5986a5a441f3a30b90c40d3e14a1837a835acccdbd725e03f2c60984f33b9912`
- Migration image: `ghcr.io/quidome/team@sha256:9caf850a1aaab72e1cb01b990e1861647380b7a19444afd336e601768f325e07`
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
- `OIDC_CLIENT_SECRET` - Pocket ID client secret.
- `SESSION_SECRET` - random value of at least 32 characters.

Reviewable non-secret values are defined in `helm-chart/values.yaml`:

- `ORIGIN=https://team.quido.me`
- `OIDC_ISSUER_URL=https://id.quido.me`
- `OIDC_CLIENT_ID=team-coordinator`
- `SESSION_TTL_SECONDS=28800`
- `DEV_AUTH_BYPASS=false`

The runtime chart stores its three Vault-provided values in a Kubernetes
Secret as base64-encoded data and exposes them to both the runtime and migration
Job via `valueFrom`. The PostgreSQL chart stores `POSTGRES_PASSWORD` in its own
Secret. Secret changes alter the runtime checksum and trigger a rollout.

## Pocket ID registration

Create the `team-coordinator` client in Pocket ID with:

- Redirect URI: `https://team.quido.me/auth/callback`
- Scope: `openid`
- Issuer: `https://id.quido.me`

Store the generated client secret at `kv/productivity/team` under
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
