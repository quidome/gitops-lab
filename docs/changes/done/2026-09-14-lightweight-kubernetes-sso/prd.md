# Product Requirements Document: Lightweight Kubernetes SSO

## 1. Introduction / Overview

This feature introduces lightweight, self-hosted single sign-on for the Kubernetes homelab without adding a full identity-management platform.

Pocket ID will provide the central OpenID Connect (OIDC) identity provider. Applications with suitable native OIDC support will integrate directly with Pocket ID. Browser-only applications that lack native OIDC may be placed behind dedicated oauth2-proxy reverse proxies after compatibility review. Applications with native clients, APIs, webhooks, or important service-to-service integrations will retain their existing authentication unless a compatible migration is demonstrated.

The implementation will be managed through the existing Argo CD and Helmfile GitOps workflow. Shared identity infrastructure will be implemented in this repository. Application-specific changes will remain in the separate repository that owns those workloads, without moving workloads between repositories.

The rollout must be incremental, reversible, and must not make Pocket ID a prerequisite for recovering Kubernetes, Argo CD, or Vault.

## 2. Goals

1. Deploy Pocket ID internally at `https://id.quido.me` using the existing Gateway API, certificate, DNS, storage, and GitOps conventions.
2. Persist Pocket ID data safely on supported persistent storage and document backup and restore procedures.
3. Integrate native OIDC with Argo CD, Grafana, Vault, and FreshRSS where the deployed versions support it cleanly.
4. Preserve independent fallback access to Argo CD and Vault when Pocket ID, the internal gateway, or DNS is unavailable.
5. Provide a low-risk oauth2-proxy proof of concept for Karma before protecting additional browser applications.
6. Prevent browser-oriented authentication from breaking application APIs, native clients, webhooks, or internal service-to-service traffic.
7. Store all OIDC client secrets, proxy cookie secrets, and Pocket ID encryption material outside Git using the existing Vault-based secret workflow.
8. Provide documentation for enrollment, client creation, recovery, backup, restore, rollback, and onboarding another application.
9. Validate all changed Helmfile configurations and rendered Kubernetes manifests before GitOps promotion.

## 3. User Stories

1. As a homelab administrator, I want to enroll a passkey in Pocket ID so that I can sign in to supported applications without maintaining separate browser passwords.
2. As an Argo CD administrator, I want to sign in with Pocket ID and receive the correct administrator or read-only role based on group membership.
3. As a Vault administrator, I want OIDC login as an additional authentication method while retaining userpass, root-token, and direct Kubernetes recovery access.
4. As a Grafana user, I want to sign in through Pocket ID while preserving the existing local administrator fallback until OIDC is verified.
5. As a FreshRSS administrator, I want native OIDC login without breaking existing data, usernames, feeds, or supported clients.
6. As a user of a browser-only dashboard, I want an unauthenticated request to redirect to Pocket ID and an authenticated request to reach the application normally.
7. As an administrator, I want to recover Argo CD and Vault without Pocket ID or the Gateway API being available.
8. As an operator of application workloads, I want existing API keys and internal Kubernetes service URLs to continue working without browser SSO redirects.
9. As a maintainer, I want to add another compatible application using a documented, repeatable process.

## 4. Functional Requirements

### Pocket ID

1. The system must deploy Pocket ID through an Argo CD-managed Helmfile release in the security infrastructure area of this repository.
2. Pocket ID must be reachable internally at `https://id.quido.me` through `gateway-internal`.
3. The Pocket ID image version must be explicitly pinned. The final version must be selected after verifying the current upstream release and deployment requirements.
4. Pocket ID must use persistent storage on the existing iSCSI storage class. SQLite data must not be placed on NFS or another network filesystem.
5. The deployment must use a safe strategy for its RWO volume, such as a StatefulSet or a Deployment with `Recreate` strategy.
6. The Pocket ID application URL and WebAuthn origin must remain stable at `https://id.quido.me`.
7. The Pocket ID encryption key must be generated outside Git, stored securely in Vault, and mounted or injected into the workload without being committed to the repository.
8. The implementation must document that losing the encryption key can make encrypted Pocket ID data unrecoverable.
9. The first administrator enrollment procedure must be documented, including passkey enrollment and verification of the first login.
10. Pocket ID must not be exposed through the external Gateway as part of this feature.

### Secret and client management

11. OIDC client secrets, oauth2-proxy cookie secrets, and other sensitive values must not be committed as plaintext or rendered into tracked files.
12. Each OIDC client must have documented redirect and post-logout URLs that exactly match the application configuration.
13. OIDC clients must use the minimum required scopes. The default scope set should be `openid profile email`; `groups` must be added only when role or access mapping requires it.
14. Secret rotation procedures must identify which Vault value, Kubernetes Secret, and workload must be updated, while preserving the existing client until the replacement is tested.

### Argo CD native OIDC

15. Argo CD must use direct OIDC configuration with Pocket ID; Dex must remain disabled unless a separate requirement is discovered.
16. The Argo CD client redirect URI must use the actual internal hostname and callback path, normally `https://argocd.quido.me/auth/callback`.
17. The Argo CD public URL configuration must be corrected from the current placeholder value to the actual route hostname before OIDC is enabled.
18. Argo CD must request group claims and map at least these groups:
    - An Argo CD administrator group to the administrator role.
    - An Argo CD read-only group to the read-only role.
19. The existing Argo CD local administrator login must remain enabled until Pocket ID login, group mapping, logout, and rollback have been verified.
20. Argo CD must remain recoverable through direct Kubernetes service access or port-forwarding without the Gateway or Pocket ID.

### Grafana native OIDC

21. Grafana must use its native Generic OAuth/OIDC integration rather than a forward-auth proxy.
22. The Grafana callback URI must use Grafana's documented generic OAuth callback path.
23. Grafana must preserve the existing local administrator login until OIDC has passed functional testing.
24. If Grafana role mapping is enabled, group claims must map administrators to the Grafana administrator role and other approved users to a non-administrator role.
25. Grafana OIDC configuration must not expose the client secret in Git or in committed rendered output.

### Vault native OIDC

26. Vault must use its native OIDC authentication method as an additive login method.
27. Vault OIDC configuration must use the exact callback URI required by the deployed Vault UI and configured auth mount.
28. Vault must retain userpass authentication, root-token recovery, unseal-key recovery, and direct Kubernetes service or port-forward access.
29. Vault OIDC groups or claims must map to explicitly documented Vault policies. Administrator access must not be granted implicitly to every authenticated Pocket ID user.
30. OIDC configuration must not disable existing Vault authentication until a successful OIDC login and an independent fallback login have both been demonstrated.

### FreshRSS native OIDC

31. FreshRSS must be evaluated using the deployed image version before configuration changes are made.
32. If the deployed version supports native OIDC cleanly, FreshRSS must use native OIDC rather than oauth2-proxy.
33. The implementation must verify the exact FreshRSS callback path, stable username claim, existing administrator username, and client compatibility before enabling OIDC.
34. Existing FreshRSS data, feeds, API access, and local administrative recovery must remain available during rollout.
35. If FreshRSS OIDC cannot be enabled without unacceptable compatibility risk, it must retain its current authentication and the reason must be documented.

### oauth2-proxy proof of concept

36. The first forward-auth proof of concept must protect Karma, because it is an internal browser-oriented dashboard with no known critical machine-to-machine dependency in the repository configuration.
37. The proof of concept must use oauth2-proxy as a reverse-proxy backend, not the unsupported Gateway API `ExternalAuth` filter.
38. The initial test must use a temporary internal hostname so the existing Karma route remains available while authentication is tested.
39. The test must verify unauthenticated redirect, successful Pocket ID login, cookie persistence, logout, authenticated access, and normal Karma functionality.
40. Only after successful testing may the primary Karma hostname be routed through oauth2-proxy.
41. The oauth2-proxy image and configuration must be explicitly pinned and its cookie secret must be stored outside Git.
42. oauth2-proxy must not be placed in front of applications whose API clients, native clients, webhooks, or service integrations cannot safely handle browser redirects.
43. Additional protected applications must be evaluated individually. A browser-only application may use a dedicated proxy instance, while an application with API or native-client requirements must retain its existing authentication unless compatibility is proven.

### Application workload integrations

44. Application-specific authentication changes must be made only in the repository that currently owns the affected workload.
45. Internal application-to-application communication must continue to use Kubernetes service DNS and existing application API keys wherever possible.
46. No public exposure may be added to an application that is currently internal.
47. No application workload may be moved between repositories as part of this feature.
48. The onboarding documentation must require an integration review covering native authentication, API clients, webhooks, native clients, redirects, and rollback before a route is protected.

### Recovery, backup, and rollback

49. Documentation must describe Argo CD recovery without Pocket ID using the retained local administrator account and direct Kubernetes access.
50. Documentation must describe Vault recovery without Pocket ID using userpass, root-token, unseal-key, and direct Kubernetes access.
51. Pocket ID backups must include its persistent data, uploads or exported data, and the encryption key.
52. The backup procedure must use the existing supported storage backup mechanism, such as TrueNAS snapshots, and must define retention and restore verification steps.
53. Pocket ID export/import must be documented as an additional recovery mechanism where supported.
54. Every OIDC or forward-auth rollout must have a documented rollback path that restores the previous application route and authentication method.
55. Existing fallback authentication must not be removed as part of the initial rollout.

### Validation and GitOps

56. Changed Helmfiles must pass the repository's existing lint and template commands.
57. Rendered manifests must pass YAML parsing and Kubernetes schema or server-side dry-run validation where available.
58. HTTPRoutes must use the existing explicit backend reference conventions and the internal Gateway.
59. No direct cluster deployment may be used as a substitute for the GitOps workflow.
60. The rollout must be staged so that Pocket ID is healthy before any dependent OIDC configuration is enabled.

## 5. Non-Goals (Out of Scope)

- Introducing Authentik, Authelia, Keycloak, or another full identity platform.
- Replacing Pocket ID with another identity provider without a concrete compatibility requirement.
- Upgrading Cilium or replacing the existing Gateway API controller to obtain reusable external authorization.
- Enabling the currently unavailable Gateway API `ExternalAuth` filter as part of the initial implementation.
- Disabling local, userpass, root-token, or other emergency authentication methods.
- Routing internal API traffic through browser-oriented SSO.
- Adding public exposure to previously internal services.
- Moving workloads between repositories.
- Automatically protecting every application route.
- Replacing application-native authentication where it is required for clients or integrations.
- Building a general-purpose identity lifecycle, directory, MFA policy, or enterprise RBAC platform.

## 6. Design Considerations

- Pocket ID must use a stable HTTPS origin because WebAuthn/passkey behavior depends on the origin.
- The Pocket ID route, Argo CD route, Grafana route, Vault route, FreshRSS route, and Karma route must remain on the internal Gateway.
- OIDC login should be additive during rollout. A successful Pocket ID login must not be considered sufficient until the fallback path is tested.
- Group membership should be limited initially to Argo CD and Vault. Grafana, FreshRSS, and forward-auth applications may use group restrictions later if their role models require them.
- The user-facing documentation should include a small client configuration table with issuer URL, redirect URI, requested scopes, secret location, and fallback method for each integrated application.
- Temporary test hostnames should be clearly marked and removed after promotion or failure.

## 7. Technical Considerations

- Existing Gateway API controller: Cilium 1.20.1.
- The live `HTTPRoute` CRD does not expose `ExternalAuth`, so oauth2-proxy must initially operate as a reverse-proxy backend.
- Existing wildcard certificate coverage includes `*.quido.me`.
- ExternalDNS observes Gateway API HTTPRoutes and will create the internal DNS record for `id.quido.me` once the route exists.
- Existing secret management uses Vault with Helmfile Vals and External Secrets infrastructure. The implementation must choose the chart-compatible mechanism for each secret without committing secret values.
- Current Argo CD configuration has a route/configuration hostname mismatch that must be resolved before direct OIDC is enabled.
- The implementation should use local minimal Helm charts where that avoids an unmaintained or non-official dependency, while keeping image versions pinned.
- Pocket ID's SQLite database must use local/block persistent storage, not NFS.
- The separate application-workload repository is in scope for later application-specific integration work, but this PRD intentionally does not enumerate its workloads.

## 8. Success Metrics

1. Pocket ID is healthy and reachable internally at `https://id.quido.me`.
2. A test administrator can enroll a passkey and complete an OIDC login.
3. Argo CD OIDC login works for both administrator and read-only group mappings.
4. Argo CD local-admin recovery works when Pocket ID is unavailable.
5. Grafana OIDC login works without removing local-admin fallback.
6. Vault OIDC login works while userpass and direct recovery paths continue to work.
7. FreshRSS either passes documented native OIDC compatibility tests or has a documented reason for retaining existing authentication.
8. Karma's oauth2-proxy proof of concept passes login, logout, redirect, and application-function tests.
9. No tested machine-to-machine integration receives an OIDC redirect or loses access because of the rollout.
10. No sensitive secret, encryption key, or recovery credential is committed to either repository.
11. All changed Helmfiles and rendered manifests pass validation.
12. A Pocket ID backup restore test successfully restores the application data and permits login.
13. Each rollout can be reverted through Git without deleting persistent application data.

## 9. Open Questions

1. Which exact Pocket ID image release should be pinned after checking the current upstream release and image documentation?
2. Which exact oauth2-proxy image release should be pinned for the Karma proof of concept?
3. What TrueNAS snapshot schedule and retention policy should be used for Pocket ID data?
4. Which FreshRSS clients and existing usernames must be included in the OIDC compatibility test?
5. What final Vault policies should be assigned to the Vault administrator and read-only groups?
6. After the Karma proof of concept, which additional browser-only applications should be evaluated first? The decision must be based on compatibility review rather than route count.
7. Should a future, separate project investigate Gateway-level external authorization after the current Gateway API and Cilium support are independently validated?

## Review Notes

This document is planning-only. It does not implement manifests, modify application configuration, create a branch, or deploy anything to the cluster. Review and approve the requirements before generating implementation tasks.
