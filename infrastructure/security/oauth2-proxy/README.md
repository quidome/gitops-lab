# Karma oauth2-proxy proof of concept

This component is a deliberately dedicated reverse proxy for testing browser
SSO in front of Karma. It is not a cluster-wide forward-auth controller and it
does not use the Gateway API `ExternalAuth` filter.

## Deployment

- **Namespace:** `security`
- **Image:** `quay.io/oauth2-proxy/oauth2-proxy:v7.15.3`
- **Temporary URL:** `https://alerts-sso.quido.me`
- **Gateway:** `gateway-internal`
- **Upstream:** `http://karma.observability.svc.cluster.local:80/`
- **Primary Karma URL:** `https://alerts.quido.me` (unchanged during the POC)

The ApplicationSet discovers `infrastructure/security/oauth2-proxy` as a
separate application. The proxy's single upstream is intentionally configured
for Karma only; each additional root hostname requires a separate review and
proxy configuration.

## Vault secret

Create the POC client in Pocket ID with this exact callback and scopes:

```text
https://alerts-sso.quido.me/oauth2/callback
openid profile email groups
```

Store the values in:

```text
kv/security/oauth2-proxy-karma
```

Required keys:

```text
oidc-client-id
oidc-client-secret
cookie-secret
```

The POC requests the `groups` claim and permits only the existing
`argocd-admins` or `argocd-readonly` Pocket ID groups. A user in another group
is denied; do not broaden this list without another compatibility review.
Register `https://alerts-sso.quido.me/` as the post-logout redirect only if
full RP-initiated logout is tested through oauth2-proxy's `rd` parameter.

Generate `cookie-secret` outside Git with a cryptographically secure generator
(for example, a URL-safe 32-byte value) and store it without a trailing newline.
Do not put any of these values in
Helm values, command history, logs, or rendered files committed to Git. The
Helmfile reads them through Vals and the Deployment receives them via
`secretKeyRef`.

The configured trusted proxy addresses are the three Cilium node addresses
used by the Pocket ID deployment. Confirm the source address seen by
`oauth2-proxy` before relying on forwarded headers; update the values file if
the Gateway uses a different address range.

## Validation and POC test

Validate the local chart and Helmfile before creating the Pocket ID client or
syncing the Application:

```bash
helm lint infrastructure/security/oauth2-proxy/helm-chart
helmfile -f infrastructure/security/oauth2-proxy/helmfile.yaml.gotmpl lint
helmfile -f infrastructure/security/oauth2-proxy/helmfile.yaml.gotmpl template
```

Inspect the result without saving secrets and verify that:

- only `gateway-internal` and `alerts-sso.quido.me` are present;
- the image is pinned to `v7.15.3`;
- the upstream is the internal Karma Service;
- cookie and client values are `secretKeyRef` entries, not plaintext values;
- `/ping` and `/ready` are proxy health endpoints.

After the Vault values and Pocket ID client exist, test the temporary host:

1. An unauthenticated browser request redirects to Pocket ID.
2. A permitted user completes login and returns to Karma.
3. The secure session cookie persists across refreshes and does not expose
   tokens to JavaScript.
4. `/oauth2/sign_out` logs out the proxy session and a subsequent Karma request
   requires login. If IdP logout is required, use an explicitly encoded `rd`
   target to Pocket ID's `/api/oidc/end-session` endpoint and test its
   registered `post_logout_redirect_uri` separately.
5. An unapproved user is denied.
6. Karma renders normally and alert acknowledgement works.
7. Any existing health, alert, or automation traffic is checked separately;
   browser redirects must not be introduced for machine clients.

Do not promote the proxy until every check passes.

## Promotion and rollback

Promotion is a separate reviewed change:

1. Add the primary host `alerts.quido.me` to this proxy route.
2. Remove or disable the direct `alerts.quido.me` HTTPRoute in the Karma
   component so only one route owns the hostname.
3. Keep the temporary host until the primary route is verified, then remove it
   and revoke its temporary Pocket ID redirect/client when no longer needed.

Rollback reverses those route changes: restore the direct Karma route, remove
the primary host from this proxy, and retain the client and Vault values until
the direct route and unauthenticated application behavior have been verified.
The Kubernetes Service DNS name and Karma's internal integrations are never
changed by this POC.
