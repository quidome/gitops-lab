# Team coordinator deployment

The Team coordinator is deployed to the `productivity` namespace through the
repository ApplicationSet and Helmfile plugin.

## Deployment contract

- Source repository: https://github.com/quidome/team
- Runtime image: `ghcr.io/quidome/team:latest` (dev phase — see below)
- Migration image: `ghcr.io/quidome/team:latest-migration` (dev phase — see below)
- PostgreSQL chart: local `postgresql-chart`
- PostgreSQL image: `docker.io/library/postgres@sha256:3c5c8892d184f738f4fe282d14ddaa613a38f00f4189d2d94725ebe6f2909ddb` (official `postgres:16-alpine`)
- Service: `team.productivity.svc.cluster.local:3000`
- PostgreSQL service: `team-postgresql.productivity.svc.cluster.local:5432`
- PostgreSQL database/role: `team`
- Public origin: `https://team.quido.me`
- Gateway: `networking/gateway-internal`

### Dev-phase image tracking

While the app is under active development, `image.tag`/`migrationImage.tag` in
`helm-chart/values.yaml` track the mutable `latest`/`latest-migration` GHCR
tags with `pullPolicy: Always`, instead of pinning to a digest. This means the
Deployment/Job specs never change between image pushes, so a plain
`kubectl rollout restart deployment/team -n productivity` (or deleting the
pod) is enough to pick up a newly published image — no commit/sync required.
`Always` still checks the registry's current digest for the tag on every pod
start and only re-pulls layers if it changed.

Before production use, switch back to digest pinning (see git history prior
to the dev-phase change for the pattern: `image.digest` /
`migrationImage.digest`, resolved from the GHCR index digest for a specific
source revision, with `pullPolicy: IfNotPresent`) so the deployed contents are
verifiable from git alone and rollouts go through Argo CD review.

The runtime image and migration image are separate OCI indexes published from
the same source revision. Migrations run as an `initContainer` on the
Deployment's own pod template, so they apply before the `team` container
starts on every pod (re)start — an Argo CD sync, a plain
`kubectl rollout restart`, or a kubelet-initiated restart after a crash or
node reschedule. A failed migration leaves the init container in
`CrashLoopBackOff`; the pod never becomes Ready, `maxUnavailable: 0` keeps the
previous pod serving traffic, and the rollout stalls until the failure is
fixed. Inspect it with
`kubectl logs -n productivity <pod> -c migration`.

This assumes `replicaCount: 1`. At a higher replica count, a rollout can start
several new pods together, each running its own migration init container
concurrently against the same database — Drizzle's migrator has no built-in
locking against that.

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
`valueFrom`, while the migration init container consumes only `DATABASE_URL`.
`OIDC_ISSUER_URL` and `OIDC_CLIENT_ID` are rendered as direct runtime environment
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
service, and a NetworkPolicy allowing only Team pods (matched by label, so it
covers the migration init container and the runtime container alike, since
both run in the same pod) to connect. The database role and database are
both `team`.

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
3. Verify the migration init container and runtime health before closing the
   change.

`POSTGRES_PASSWORD` initializes the PostgreSQL role; changing the Kubernetes
Secret alone does not change an already-initialized database role. Rotate the
database credential during a maintenance window: change the PostgreSQL role
password, update `POSTGRES_PASSWORD` and `DATABASE_URL` together in Vault, then
sync and verify the migration init container and readiness. Retain the PostgreSQL volume
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
