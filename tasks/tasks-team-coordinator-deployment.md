# Implementation Tasks: Team Coordinator Deployment

Based on the Team application deployment contract in the separate `quidome/team` repository.

## Relevant files and systems

- `tasks/tasks-team-coordinator-deployment.md` - This implementation checklist.
- `applications/<selected-realm>/team/helmfile.yaml` or `helmfile.yaml.gotmpl` - Team release definition; select the realm using repository conventions before implementation.
- `applications/<selected-realm>/team/helm-chart/` - Local chart for the Team runtime Deployment, Service, migration Job, and configuration.
- `applications/<selected-realm>/team/resources/` - HTTPRoute, ExternalSecret/secret references, NetworkPolicy, and other repository-standard resources when needed.
- `infrastructure/security/vault/` - Vault paths, Vals usage, and secret recovery procedures.
- `infrastructure/networking/gateway/` - Existing Gateway API and certificate conventions.
- `infrastructure/applicationset.yaml` - Confirm the selected application path is discovered automatically.
- `https://github.com/quidome/team` - Application source repository and container workflow.
- `ghcr.io/quidome/team` - Public runtime and migration images.

## Deployment contract

- Runtime image: `ghcr.io/quidome/team:<verified-version>`.
- Migration image: `ghcr.io/quidome/team:<verified-version>-migration` or the equivalent immutable tag produced by the Team repository workflow.
- The migration image is a one-shot job and must complete before the runtime is considered ready.
- Runtime listens on container port `3000` by default.
- Liveness endpoint: `/api/health/liveness`.
- Readiness endpoint: `/api/health/readiness`.
- The runtime image contains no application secrets or deployment-specific configuration.
- Prefer immutable SHA or digest-pinned image references in GitOps. Do not deploy `latest` unless the rollout explicitly records the verified source revision.
- The current Team lifecycle commit must be published before selecting an image that claims to contain it; verify the image digest/source revision rather than assuming the existing `latest` tag is current.

## Required runtime configuration

Inject these values at deployment time through the repository's approved Vault/Vals workflow. Never commit rendered values or secret contents.

- `DATABASE_URL` - PostgreSQL URL using the cluster service hostname, not `localhost`.
- `ORIGIN` - Exact public HTTPS URL for the Team application.
- `OIDC_ISSUER_URL` - Pocket ID issuer URL.
- `OIDC_CLIENT_ID` - Pocket ID client identifier.
- `OIDC_CLIENT_SECRET` - Pocket ID client secret.
- `SESSION_SECRET` - Random secret of at least 32 characters.
- `SESSION_TTL_SECONDS` - Coordinator session lifetime.
- Optional `HOST` and `PORT` only when overriding the image defaults.
- Keep `DEV_AUTH_BYPASS` unset or `false`; it is ignored by production builds and must not be used as production authentication.

Register `${ORIGIN}/auth/callback` as the exact Pocket ID redirect URI. Use the production HTTPS origin consistently in Pocket ID, the HTTPRoute, DNS, and the application environment.

## Instructions for completing tasks

As tasks are completed, check them off by changing `- [ ]` to `- [x]`. Update this file after each subtask, not only after an entire parent task.

Do not deploy directly with `helm install`, `helm upgrade`, or `kubectl apply`. Validate changes locally and promote them through the repository's Argo CD GitOps workflow after review.

## Tasks

- [ ] 0.0 Confirm deployment assumptions and source artifacts
  - [x] 0.1 Confirm the target realm/namespace, public hostname, Gateway, certificate, and DNS ownership using existing repository conventions.
  - [x] 0.2 Confirm the Team source revision to deploy and publish/verify matching runtime and migration images in GHCR.
  - [x] 0.3 Record immutable runtime and migration image references, preferably digests or verified SHA-based tags.
  - [x] 0.4 Confirm the Argo CD ApplicationSet discovers the selected application path without an unnecessary ApplicationSet change.
  - [ ] 0.5 Confirm the production PostgreSQL provision, database name, role, network access, backup ownership, and restore procedure.
  - [ ] 0.6 Confirm the Pocket ID base URL, client registration process, callback URL, required scopes, and client-secret storage path.

- [x] 1.0 Create the GitOps application component
  - [x] 1.1 Create the component directory using the repository's Helmfile layout and selected realm.
  - [x] 1.2 Add a pinned Helmfile release and local chart when the application needs repository-specific control.
  - [x] 1.3 Add a Deployment for the runtime image with repository-standard labels, security settings, resource requests, and memory limits.
  - [x] 1.4 Use CPU requests without CPU limits and equal memory requests/limits, following the repository convention.
  - [x] 1.5 Add a ClusterIP Service targeting container port `3000`.
  - [x] 1.6 Configure liveness and readiness probes against the Team health endpoints.
  - [x] 1.7 Configure a safe rolling strategy and pod security context suitable for the image.
  - [x] 1.8 Render the chart and inspect namespaces, labels, ports, probes, resources, and image references.

- [x] 2.0 Run database migrations as an ordered one-shot workload
  - [x] 2.1 Add a migration Job or repository-standard Argo CD hook using the migration image.
  - [x] 2.2 Ensure the migration workload receives the same `DATABASE_URL` as the runtime without duplicating secret values.
  - [x] 2.3 Configure retry, completion, cleanup, and sync-wave behavior so migrations finish before runtime rollout.
  - [x] 2.4 Ensure migration reruns are safe and do not create duplicate Jobs or block future upgrades.
  - [x] 2.5 Define failure behavior: runtime must not be promoted as healthy when the migration job fails.
  - [x] 2.6 Validate the migration manifest and document the rollback boundary for schema changes.

- [ ] 3.0 Configure Vault/Vals secrets and runtime environment
  - [x] 3.1 Select and document the Vault path using the repository naming convention, for example `kv/<realm>/team`.
  - [x] 3.2 Inject `DATABASE_URL`, OIDC client secret, and session secret without committing values to Git.
  - [x] 3.3 Keep non-secret runtime values reviewable in Helm values while keeping deployment-specific values out of the image.
  - [x] 3.4 Confirm no rendered manifests, Helmfile output, logs, or task artifacts contain plaintext secrets.
  - [x] 3.5 Document secret rotation for the database credential, Pocket ID client secret, and session secret, including expected session invalidation.

- [ ] 4.0 Provision and secure PostgreSQL connectivity
  - [ ] 4.1 Create or select the production database, role, and schema required by the Team migrations.
  - [ ] 4.2 Store the complete PostgreSQL connection string in the approved secret workflow.
  - [x] 4.3 Add only the required NetworkPolicy and database network access.
  - [ ] 4.4 Run the migration job against the real PostgreSQL service and verify readiness afterward.
  - [ ] 4.5 Confirm scheduled backups, retention, isolated restore verification, and ownership outside the application chart.

- [ ] 5.0 Expose the application through HTTPS and Pocket ID
  - [x] 5.1 Add an HTTPRoute following existing Gateway API examples with explicit backend defaults.
  - [x] 5.2 Configure DNS and certificate issuance for the selected hostname.
  - [x] 5.3 Set `ORIGIN` to the exact HTTPS route URL.
  - [ ] 5.4 Register the exact `${ORIGIN}/auth/callback` redirect URI in Pocket ID.
  - [ ] 5.5 Configure the Pocket ID issuer, client ID, client secret, and required scopes.
  - [ ] 5.6 Confirm unauthenticated application routes redirect to Pocket ID while liveness remains usable for infrastructure health checks.
  - [ ] 5.7 Verify readiness returns HTTP 200 only when PostgreSQL is available.

- [ ] 6.0 Validate, roll out, and document operations
  - [x] 6.1 Run Helmfile lint and render checks for the changed component.
  - [x] 6.2 Run local Helm chart lint/template checks and static YAML/Kubernetes schema validation.
  - [x] 6.3 Review the final diff for plaintext secrets, `localhost` database URLs, mutable image tags, public exposure mistakes, and missing probes/resources.
  - [ ] 6.4 Promote through Argo CD only after review and image verification.
  - [ ] 6.5 Verify migration completion, runtime health, HTTPS, Pocket ID login, protected API access, and clean shutdown behavior.
  - [ ] 6.6 Run the Team production smoke check against the deployed HTTPS origin.
  - [ ] 6.7 Document rollback to the previous image and the database migration recovery boundary.
  - [ ] 6.8 Document the deployed hostname, namespace, image references, Vault paths, backup owner, and operational recovery commands without recording secret values.

## Acceptance criteria

- The Team runtime is reachable over the intended HTTPS hostname.
- Pocket ID login succeeds using the exact configured callback URL.
- PostgreSQL migrations complete before the runtime rollout and readiness is healthy.
- Liveness is dependency-light; readiness reports database availability.
- No secret values are present in Git, container images, rendered manifests, or CI logs.
- Production smoke checks pass for liveness, readiness, authentication protection, and clean shutdown.
- The deployment can be rolled back without silently skipping or reversing database migrations.
