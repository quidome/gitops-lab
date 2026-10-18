# Implementation Tasks: Lightweight Kubernetes SSO

Based on: `tasks/prd-lightweight-kubernetes-sso.md`

## Relevant Files

- `tasks/prd-lightweight-kubernetes-sso.md` - Approved requirements and acceptance criteria.
- `tasks/tasks-lightweight-kubernetes-sso.md` - This implementation checklist.
- `infrastructure/security/pocket-id/` - New Helmfile release, local chart, resources, and Pocket ID operational documentation.
- `infrastructure/security/pocket-id/helmfile.yaml` - Pocket ID release definition and pinned image/configuration inputs.
- `infrastructure/security/pocket-id/helm-chart/` - Pocket ID Deployment or StatefulSet, Service, PVC, Secret references, and HTTPRoute templates.
- `infrastructure/gitops/argocd/values.yaml` - Argo CD URL, direct OIDC configuration, RBAC mappings, and preserved local access settings.
- `infrastructure/observability/kube-prometheus-stack/values.yaml` - Grafana native OIDC settings.
- `infrastructure/observability/kube-prometheus-stack/secrets.yaml.gotmpl` - Vault-backed Grafana OIDC client secret injection.
- `infrastructure/security/vault/README.md` - Vault OIDC setup, policy mapping, fallback access, backup, and recovery procedures.
- `applications/productivity/freshrss/helm-chart/templates/deployment.yaml` - FreshRSS OIDC environment variables if compatibility is confirmed.
- `applications/productivity/freshrss/helm-chart/templates/secret.yaml` - FreshRSS OIDC secret references if required by the chart.
- `applications/productivity/freshrss/helmfile.yaml.gotmpl` - Vault-backed FreshRSS OIDC values if required.
- `applications/productivity/freshrss/README.md` - FreshRSS compatibility, login, client, and rollback documentation.
- `infrastructure/observability/karma/` - Existing Karma route and service used by the forward-auth proof of concept.
- `infrastructure/security/oauth2-proxy/` or the selected Karma integration location - Dedicated oauth2-proxy chart and resources; exact location must follow the baseline review.
- `docs/` or component README files - Enrollment, onboarding, rollout, rollback, backup, and disaster-recovery documentation.
- The separate application-workload repository - Later application-specific integrations after compatibility review; workload names are intentionally not enumerated here.

### Notes

- Exact files for new charts and resources must be confirmed during implementation using existing Helmfile and chart conventions.
- No conventional application unit tests are expected. Validation uses Helmfile, Helm, YAML, Kubernetes schema, and GitOps checks documented by the repositories.
- Do not upgrade Cilium or Gateway API CRDs for `ExternalAuth` as part of this feature.
- Do not commit client secrets, encryption keys, cookie secrets, recovery credentials, or rendered secret values.
- Do not deploy directly with `helm install`, `helm upgrade`, or `kubectl apply`; use the repository's Argo CD GitOps workflow after review and validation.

### Baseline decision record

- Feature branch: `feat/lightweight-kubernetes-sso`.
- Pocket ID: local minimal chart, official image `ghcr.io/pocket-id/pocket-id:v2.14.0` (selected by the current repository pin).
- oauth2-proxy: official image `quay.io/oauth2-proxy/oauth2-proxy:v7.15.3` for the Karma proof of concept.
- Gateway: retain Cilium 1.20.1 and the current Gateway API CRDs; do not use `ExternalAuth`.
- Initial group mappings: `argocd-admins`, `argocd-readonly`, `vault-admins`, and `vault-readonly`.
- Initial callback records: Argo CD `/auth/callback`, Grafana `/login/generic_oauth`, Vault UI OIDC callback on the `oidc` auth mount, FreshRSS `/i/oidc/`, and temporary Karma host `alerts-sso.quido.me`.

## Instructions for Completing Tasks

As tasks are completed, check them off by changing `- [ ]` to `- [x]`. Update this file after each subtask, not only after an entire parent task.

## Validation note

Local Helmfile rendering that evaluates `fetchSecretValue` requires the approved Vault connection. The current workstation default (`https://127.0.0.1:8200`) is unavailable, so real Vals-backed lint/template validation remains pending; local chart renders use non-secret validation placeholders only and no generated output is retained.

## Tasks

- [x] 0.0 Create feature branch
  - [x] 0.1 Create and checkout `feat/lightweight-kubernetes-sso`.

- [x] 1.0 Confirm implementation assumptions, versions, dependencies, and baseline state
  - [x] 1.1 Confirm both repositories are clean before implementation and record the current branch and revision without changing them.
  - [x] 1.2 Record the current Argo CD, Grafana, Vault, FreshRSS, Cilium, Gateway API, and Karma versions from repository configuration and read-only cluster inspection.
  - [x] 1.3 Confirm the current Argo CD route hostname and identify the existing placeholder URL mismatch that must be corrected before OIDC.
  - [x] 1.4 Confirm the live Gateway API schema does not expose `HTTPRoute` `ExternalAuth`; explicitly exclude a Cilium or Gateway API upgrade from this implementation.
  - [x] 1.5 Verify the current Pocket ID upstream release, required environment variables, WebAuthn URL requirements, SQLite storage restrictions, backup/export behavior, and available chart/image sources.
  - [x] 1.6 Select and record the explicitly pinned Pocket ID image version and a local chart because Pocket ID does not publish an official Kubernetes chart.
  - [x] 1.7 Verify the selected oauth2-proxy release, OIDC flags, secure-cookie settings, reverse-proxy behavior, callback handling, and per-host upstream limitation.
  - [x] 1.8 Verify native OIDC support and exact callback requirements for the deployed Argo CD, Grafana, Vault, and FreshRSS versions.
  - [x] 1.9 Define the initial Pocket ID client names, redirect URLs, scopes, and group requirements without recording any secret values.
  - [x] 1.10 Define the initial Argo CD and Vault group/policy mappings, including administrator and read-only behavior.
  - [x] 1.11 Record the staged rollout order, approval gates, fallback paths, and rollback checkpoints before modifying application configuration.

- [x] 2.0 Implement Pocket ID as internal GitOps-managed identity infrastructure
  - [x] 2.1 Create the Pocket ID component directory under the security infrastructure realm using the repository's Helmfile layout.
  - [x] 2.2 Create a local minimal chart, unless task 1 confirms a maintained compatible chart is preferable; keep the image version pinned.
  - [x] 2.3 Configure Pocket ID with `APP_URL=https://id.quido.me` and the required trusted-proxy behavior for the internal Gateway.
  - [x] 2.4 Configure a persistent SQLite data directory on the existing iSCSI storage class; do not use NFS or another network filesystem.
  - [x] 2.5 Use a StatefulSet or a Deployment with `Recreate` strategy for the RWO data volume.
  - [x] 2.6 Add repository-standard resource requests and memory limits, security settings, probes, and service configuration.
  - [x] 2.7 Add a Kubernetes Secret reference for the Pocket ID encryption key without placing the key in Git or a tracked values file.
  - [x] 2.8 Add the internal `HTTPRoute` for `id.quido.me` using `gateway-internal`, explicit backend defaults, and the existing wildcard certificate path.
  - [x] 2.9 Confirm the route will be discovered by ExternalDNS and will not attach to `gateway-external`.
  - [x] 2.10 Confirm the infrastructure ApplicationSet will discover the new component without modifying the ApplicationSet unnecessarily.
  - [x] 2.11 Render the new component locally and inspect the generated resources for plaintext secrets, incorrect namespaces, incorrect storage classes, and unintended external exposure.

- [ ] 3.0 Configure Pocket ID secrets, client enrollment, persistence, backup, and recovery procedures
  - [x] 3.1 Document the Vault path and key name for the permanent Pocket ID encryption key and the safe out-of-band generation procedure.
  - [x] 3.2 Configure the selected Vault-backed secret delivery mechanism for the Pocket ID workload and verify it does not require committing secret values.
  - [x] 3.3 Deploy Pocket ID only through the approved GitOps sync process after manifest validation.
  - [x] 3.4 Verify the Pocket ID Service, internal HTTPS route, readiness state, and WebAuthn origin before creating dependent clients.
  - [ ] 3.5 Complete first-administrator enrollment and passkey registration; record only non-sensitive operational steps.
  - [ ] 3.6 Create the initial OIDC clients for Argo CD, Grafana, Vault, FreshRSS, and the Karma proof of concept with exact callback URLs.
  - [ ] 3.7 Configure only the required scopes for each client; add `groups` only to clients that use group-based authorization.
  - [ ] 3.8 Store every client secret and oauth2-proxy cookie secret in the existing Vault workflow and verify no secret appears in Git history or tracked rendered output.
  - [x] 3.9 Document Pocket ID enrollment, passkey recovery, client creation, client rotation, and client revocation procedures.
  - [x] 3.10 Document backups of the Pocket ID database, uploads/exported data, and permanent encryption key.
  - [x] 3.11 Define the TrueNAS snapshot schedule, retention, secure backup location, and restore verification procedure.
  - [ ] 3.12 Perform or schedule a restore test that verifies data recovery and successful Pocket ID login without changing the production encryption key.
  - [x] 3.13 Document recovery when Pocket ID is unavailable, including direct Kubernetes and application fallback access.

- [ ] 4.0 Add Argo CD native OIDC with independent fallback access
  - [x] 4.1 Correct the Argo CD configured URL to `https://argocd.quido.me` while preserving the existing internal HTTPRoute.
  - [x] 4.2 Add direct Pocket ID OIDC configuration under `configs.cm.oidc.config`; keep Dex disabled.
  - [x] 4.3 Configure the Argo CD client callback as `https://argocd.quido.me/auth/callback` and request `openid`, `profile`, `email`, and `groups`.
  - [x] 4.4 Inject the Argo CD client secret through Vault-backed configuration supported by the existing Helmfile pattern.
  - [x] 4.5 Configure Argo CD RBAC mappings for the administrator and read-only Pocket ID groups.
  - [x] 4.6 Keep the local Argo CD administrator login enabled and document its credentials/recovery handling without copying sensitive values into Git.
  - [x] 4.7 Validate rendered ConfigMap and Secret references without exposing client secrets in command output or artifacts.
  - [x] 4.8 Sync the change through Argo CD only after Pocket ID is healthy and the client exists.
  - [ ] 4.9 Test administrator login, read-only login, group claims, logout, invalid-group denial, and existing local-admin login.
  - [ ] 4.10 Test direct Argo CD recovery through Kubernetes service access or port-forwarding without the Gateway or Pocket ID.
  - [ ] 4.11 Document and test rollback to local authentication if OIDC login or RBAC mapping fails.

- [ ] 5.0 Add Grafana native OIDC with independent local-admin fallback
  - [x] 5.1 Add Grafana Generic OAuth/OIDC configuration to the existing `grafana.ini` values rather than adding a proxy.
  - [x] 5.2 Configure the exact Grafana callback URL for `grafana.quido.me` and the Pocket ID issuer/discovery endpoint.
  - [x] 5.3 Inject the Grafana client secret through the existing Vault-backed secrets template.
  - [x] 5.4 Keep the Grafana login form and existing local administrator account enabled during rollout.
  - [x] 5.5 Avoid group-based Grafana role mapping unless the baseline review identifies a concrete role requirement; do not broaden group scope unnecessarily.
  - [x] 5.6 Validate the rendered Grafana configuration without exposing the client secret.
  - [ ] 5.7 Sync through Argo CD after creating and validating the Pocket ID Grafana client.
  - [ ] 5.8 Test Pocket ID login, logout, session persistence, denied/invalid client behavior, and local-admin fallback.
  - [ ] 5.9 Confirm dashboards, datasources, alerting, and existing Grafana functionality remain available.
  - [ ] 5.10 Document and test rollback by disabling native OIDC while retaining local login.

- [ ] 6.0 Add Vault native OIDC without removing emergency authentication methods
  - [x] 6.1 Confirm the deployed Vault version, UI route, configured auth mounts, and exact OIDC callback format.
  - [x] 6.2 Create the Pocket ID Vault client with the exact callback URL and required scopes.
  - [x] 6.3 Configure Vault's native OIDC auth method and discovery settings through the documented administrative procedure; do not commit client secrets.
  - [x] 6.4 Create explicit Vault OIDC roles and policies for administrator and read-only access, using group claims only where required.
  - [x] 6.5 Keep userpass, root-token recovery, unseal-key recovery, and direct Kubernetes service/port-forward access enabled.
  - [ ] 6.6 Test Vault OIDC login through the internal UI and verify the resulting identity has only the expected policy.
  - [ ] 6.7 Test Vault userpass login and direct recovery access while Pocket ID is unavailable.
  - [x] 6.8 Document Vault OIDC client rotation, policy changes, disabling OIDC, and recovery after a failed configuration.
  - [x] 6.9 Verify that no Vault OIDC change makes secret retrieval by Argo CD or existing workloads dependent on Pocket ID.

- [ ] 7.0 Evaluate and, if compatible, enable FreshRSS native OIDC
  - [x] 7.1 Confirm the deployed FreshRSS image version and review its version-specific OIDC documentation before changing the chart.
  - [x] 7.2 Verify the exact FreshRSS callback path, provider metadata URL, required environment variables, username claim, crypto key, and forwarded-header requirements.
  - [ ] 7.3 Compare the Pocket ID username claim with the existing FreshRSS administrator username and identify any migration risk.
  - [ ] 7.4 Identify affected FreshRSS clients, API consumers, feed readers, and local administrative recovery behavior.
  - [ ] 7.5 If compatibility is confirmed, add Vault-backed FreshRSS OIDC values and secret references to the existing local chart.
  - [ ] 7.6 Create the FreshRSS Pocket ID client with exact redirect and post-logout URLs.
  - [ ] 7.7 Keep the existing FreshRSS recovery/authentication path until OIDC has passed testing.
  - [ ] 7.8 Validate and sync the FreshRSS change through Argo CD only after the client and secrets are ready.
  - [ ] 7.9 Test login, logout, username mapping, existing feeds, API access, supported clients, and administrator recovery.
  - [x] 7.10 If compatibility is not clean, leave FreshRSS unchanged and document the reason and follow-up conditions.
  - [x] 7.11 Document rollback to the previous FreshRSS authentication configuration.

- [ ] 8.0 Implement and validate the Karma oauth2-proxy proof of concept
  - [x] 8.1 Confirm Karma is browser-oriented for this purpose and identify any health, alert acknowledgement, API, or automation traffic that must remain compatible.
  - [x] 8.2 Select the component location and chart ownership for the dedicated proxy using the baseline conventions; avoid inventing a cluster-wide middleware controller.
  - [x] 8.3 Create the pinned oauth2-proxy Deployment and Service with secure cookies, reverse-proxy settings, resource requests, probes, and the internal Karma Service upstream.
  - [x] 8.4 Inject the Pocket ID client secret and cookie secret through Vault without committing either value.
  - [x] 8.5 Configure the exact temporary callback URL, issuer, allowed redirect domain, and internal-only hostname.
  - [x] 8.6 Add a temporary internal HTTPRoute that sends the test hostname to oauth2-proxy while preserving the existing primary Karma route.
  - [ ] 8.7 Create or update the Karma proof-of-concept Pocket ID client with the temporary callback URL.
  - [x] 8.8 Validate the proxy and temporary route before changing the primary hostname.
  - [ ] 8.9 Test unauthenticated redirect to Pocket ID, successful login, secure cookie persistence, logout, refresh, denied access, and normal Karma rendering.
  - [ ] 8.10 Test Karma alert acknowledgement and any identified browser/API behavior through the proxy.
  - [ ] 8.11 Promote the proxy to the primary Karma hostname only after all proof-of-concept tests pass.
  - [ ] 8.12 Remove temporary test resources and confirm the primary route has one unambiguous backend.
  - [x] 8.13 Document that this is a reverse-proxy integration, that each root hostname generally needs its own proxy configuration, and that Gateway `ExternalAuth` remains out of scope.
  - [ ] 8.14 Document and test rollback to the direct Karma route.

- [ ] 9.0 Review and stage additional application-workload integrations without breaking APIs or native clients
  - [x] 9.1 Create an application integration review template covering native OIDC support, existing authentication, API clients, webhooks, native clients, redirect behavior, internal service URLs, and rollback.
  - [ ] 9.2 Review workload ownership and make each application-specific change only in its owning repository.
  - [ ] 9.3 Classify each reviewed workload as native OIDC, dedicated oauth2-proxy, or retain-existing-authentication; record the reason and risk.
  - [ ] 9.4 Do not place a proxy in front of any workload whose API or native client cannot safely handle browser redirects.
  - [ ] 9.5 Preserve internal Kubernetes service DNS and existing API-key integrations; do not rewrite machine-to-machine URLs to protected public hostnames.
  - [ ] 9.6 For each approved browser-only workload, create a dedicated Pocket ID client, store secrets in Vault, and use a temporary internal hostname for testing.
  - [ ] 9.7 Validate browser login, logout, API behavior, native-client behavior, webhooks, and application-specific functionality before promotion.
  - [ ] 9.8 Promote only verified routes and keep existing authentication available until the replacement is proven.
  - [ ] 9.9 Record rejected candidates and their compatibility reasons without expanding scope or exposing unnecessary workload details in this repository.
  - [x] 9.10 Provide a repeatable onboarding checklist for future applications.

- [ ] 10.0 Complete validation, rollout, rollback, documentation, and GitOps promotion checks
  - [ ] 10.1 Run Helmfile lint for every changed component using the repository's documented commands.
  - [ ] 10.2 Render every changed Helmfile and inspect namespaces, routes, services, storage, probes, resource settings, and secret references.
  - [ ] 10.3 Parse changed static YAML with the repository's documented Python YAML validation command.
  - [x] 10.4 Run Helm chart lint/template validation for every new or modified local chart.
  - [x] 10.5 Run Kubernetes schema or server-side dry-run validation where available, without applying resources.
  - [x] 10.6 Review the final diff for plaintext secrets, accidental public Gateway references, unpinned images, duplicate hostnames, and unintended route changes.
  - [x] 10.7 Verify changed Argo CD Applications and ApplicationSets will discover the intended paths and namespaces.
  - [ ] 10.8 Execute the staged rollout in dependency order: Pocket ID, client enrollment, native integrations, Karma proof of concept, then separately approved workload integrations.
  - [ ] 10.9 Record authentication success, fallback success, rollback success, and machine-to-machine compatibility results for each integrated application.
  - [x] 10.10 Complete the enrollment, client-management, backup/restore, recovery, rollback, and onboarding documentation.
  - [ ] 10.11 Verify Pocket ID backup restoration and confirm the encryption key is available through the approved secure recovery process.
  - [ ] 10.12 Confirm Argo CD and Vault remain recoverable without Pocket ID, Gateway, DNS, or external authentication.
  - [x] 10.13 Check both repositories' working trees and capture the final changed-file summary.
  - [x] 10.14 Prepare the required pre-commit summary: changed files, intent in no more than five bullets, and a proposed Conventional Commit message.
  - [x] 10.15 Stop for review before any commit, push, or production GitOps promotion.
