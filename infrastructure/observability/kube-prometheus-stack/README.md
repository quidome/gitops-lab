# Observability

The kube-prometheus-stack release exposes Grafana internally at:

```text
https://grafana.quido.me
```

## Pocket ID OIDC

Grafana uses its native Generic OAuth integration. It is not placed behind an
OIDC proxy. The current Grafana image is `docker.io/grafana/grafana:13.2.1`
from kube-prometheus-stack `90.0.0`.

Create a confidential Pocket ID client with:

- **Issuer:** `https://id.quido.me`
- **Redirect URI:** `https://grafana.quido.me/login/generic_oauth`
- **Scopes:** `openid profile email`
- **Groups:** not requested; Grafana role mapping is intentionally not enabled

Store the generated client values in Vault at:

```text
kv/observability/grafana
```

Required keys:

```text
oidc-client-id
oidc-client-secret
```

The existing `admin-password` key remains the local-admin fallback. The
Helmfile creates `grafana-auth-generic-oauth` from these Vault values and
mounts it as files. `grafana.ini` reads the files with Grafana's native
`$__file{...}` provider, so the credentials are not written to the Grafana
ConfigMap.

## Rollout

1. Verify Pocket ID is healthy and create the Grafana client with the exact
   redirect URI above.
2. Add the client ID and secret to the Vault path above without committing
   either value.
3. Render and inspect the Helmfile; do not save rendered secrets in the
   repository or share the rendered output.
4. Sync `kube-prometheus-stack` through Argo CD.
5. Test Pocket ID login, logout, session persistence, dashboard access,
   datasources, alerting, and the retained local `admin` login.

OIDC users are created with Grafana's default non-administrator role. No
Pocket ID group is granted Grafana administrator access by this configuration.

## Rollback and recovery

To roll back, remove the `auth.generic_oauth` block and its
`extraSecretMounts` entry, then sync through Argo CD. Keep the Pocket ID
client and Vault values until rollback has been verified; revoke them later if
needed.

The local login form remains enabled. If the Gateway or Pocket ID is
unavailable, use direct Kubernetes access:

```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
```

Then open `http://127.0.0.1:3000` and use the retained local administrator
credentials.
