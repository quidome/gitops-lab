# Lightweight Kubernetes SSO application onboarding

Use this checklist before protecting an internal application with Pocket ID.
This repository owns shared identity infrastructure; application-specific
changes stay in the repository that owns the workload.

## Compatibility review

- [ ] Identify the deployed image/version and confirm native OIDC support,
      callback path, issuer/discovery URL, username claim, and logout behavior.
- [ ] Record the current authentication method and a tested break-glass path.
- [ ] List browser routes, API routes, webhooks, health checks, automation,
      native clients, feed readers, and service-to-service callers.
- [ ] Keep Kubernetes Service DNS and existing API keys for machine traffic.
- [ ] Decide one outcome: native OIDC, a dedicated oauth2-proxy, or retain the
      existing authentication. Record the compatibility reason.

## Client and route preparation

- [ ] Create a dedicated Pocket ID client with exact redirect and post-logout
      URLs. Use only `openid profile email`; add `groups` only for an explicit
      role/access mapping.
- [ ] Store the client ID/secret and any proxy cookie or application crypto key
      in the owning Vault path. Generate secrets outside Git.
- [ ] Use `gateway-internal` only. For a proxy, test a temporary internal
      hostname first and leave the current route available.
- [ ] For native OIDC, verify the application origin and forwarded headers
      expected by its deployed version.

## Test, promote, and recover

- [ ] Render and inspect manifests for namespace, pinned images, route/backend
      ownership, secret references, and absence of plaintext secrets.
- [ ] Test login, logout, session persistence, denied access, and the normal
      application workflow.
- [ ] Test APIs, webhooks, health checks, native clients, and internal callers;
      confirm none receive an interactive redirect unexpectedly.
- [ ] Test the existing local/emergency authentication independently while the
      new path is enabled.
- [ ] Promote only after all tests pass and record the result.
- [ ] Document rollback: restore the direct route or previous auth, keep
      persistent data and secrets until recovery is verified, then revoke
      unused Pocket ID clients.

Do not add public exposure, move workloads between repositories, or use the
Gateway API `ExternalAuth` filter as part of this process.
