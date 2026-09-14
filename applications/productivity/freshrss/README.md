# FreshRSS

Initial GitOps scaffold for internal-only FreshRSS deployment.

## Notes

- Uses a local minimal Helm chart (`helm-chart/`) for full control.
- Persists FreshRSS data at `/var/www/FreshRSS/data` on an RWO PVC.
- Deployment strategy is `Recreate` to avoid RWO multi-attach issues.
- Exposed internally via `gateway-internal` at `https://rss.quido.me`.

## Authentication compatibility decision

The deployed image is `freshrss/freshrss:1.30.0`. Its default Debian image
includes Apache `mod_auth_openidc` and supports native OIDC using
[FreshRSS's OIDC configuration](https://freshrss.github.io/FreshRSS/en/admins/16_OpenID-Connect.html):
`OIDC_ENABLED`, `OIDC_PROVIDER_METADATA_URL`, `OIDC_CLIENT_ID`,
`OIDC_CLIENT_SECRET`, `OIDC_CLIENT_CRYPTO_KEY`, `OIDC_REMOTE_USER_CLAIM`,
`OIDC_SCOPES`, and `OIDC_X_FORWARDED_HEADERS`. The callback is
`/i/oidc/`.

Native OIDC is **not enabled in this rollout**. FreshRSS protects its `/i`
application directory with Apache OIDC and requires the configured
`preferred_username` to match the existing FreshRSS username exactly,
including case. Pocket ID usernames are lowercase. The deployed instance's
existing administrator username and client compatibility have not been
verified, and enabling OIDC would remove the current local browser login
rather than provide an additive fallback. That does not meet the initial
rollout requirement to preserve local administrative recovery.

The FreshRSS API remains under `/api`, but this is not sufficient to call the
UI recovery path compatible: feed readers, API consumers, existing data, and
administrator recovery must be tested together before changing authentication.
Keep the current authentication and client until that review is complete.

If a later reviewed rollout proceeds, create a Pocket ID client with:

```text
Redirect URI: https://rss.quido.me/i/oidc/
Scopes:       openid profile email
Issuer:       https://id.quido.me
Username:     preferred_username (must equal the existing FreshRSS admin)
```

Store these values in `kv/productivity/freshrss` using the additional keys
`oidc-client-id`, `oidc-client-secret`, and `oidc-client-crypto-key` (a
random value generated outside Git, without a trailing newline). Inject them
with `secretKeyRef`; never commit them. The deployment must also set
`OIDC_X_FORWARDED_HEADERS` to the forwarded host, port, and protocol headers
actually supplied by the internal Gateway. Enable OIDC only after a backup,
client test, and rollback window are approved.

## Recovery and rollback

To retain the current behavior, do not set `OIDC_ENABLED`. If a future OIDC
rollout prevents UI access, remove the OIDC environment settings and sync the
previous chart configuration through Argo CD; do not delete the FreshRSS PVC.
The existing API and data must be verified after the rollback. Keep the
Pocket ID client and Vault values until recovery has been confirmed, then
revoke them if the rollout is abandoned.

## Existing setup and follow-up items

- Populate Vault path `kv/productivity/freshrss` with keys:
  - `FRESHRSS_USER`
  - `FRESHRSS_PASSWORD`
- Secrets are injected at deploy-time via Vals in `helmfile.yaml.gotmpl` and rendered into Kubernetes Secret `freshrss-auth`.
- Deployment consumes credentials via `secretKeyRef` (credentials are not embedded directly in Deployment env values).
- Validate iOS client compatibility and document tested client(s).
- Decide whether to keep SQLite-only or move to PostgreSQL/MariaDB.
