# Argo CD

Argo CD is deployed in the `gitops` namespace and is exposed internally at:

```text
https://argocd.quido.me
```

## Pocket ID OIDC

The Helmfile configures direct OIDC against Pocket ID. Dex remains disabled.

Pocket ID client settings:

- **Issuer:** `https://id.quido.me`
- **Callback:** `https://argocd.quido.me/auth/callback`
- **Scopes:** `openid profile email groups`
- **Client type:** confidential

The client ID and client secret are read from Vault at:

```text
kv/gitops/argocd
```

Keys:

```text
oidc-client-id
oidc-client-secret
```

The client secret is injected into `argocd-secret` during Argo CD's Helmfile rendering. It must not be committed to Git.

## Group access

Pocket ID groups map to Argo CD RBAC roles:

| Pocket ID group | Argo CD role |
| --- | --- |
| `argocd-admins` | `role:admin` |
| `argocd-readonly` | `role:readonly` |

The default OIDC policy is empty, so users must belong to one of the mapped groups to receive Argo CD permissions.

## Break-glass access

Do not disable the local Argo CD administrator account. It is required when Pocket ID, DNS, or the Gateway is unavailable.

Use direct Kubernetes service access or port-forwarding:

```bash
kubectl port-forward -n gitops svc/argocd-server 8080:80
```

Then open `http://127.0.0.1:8080` and use the retained local administrator credentials.

## Validation

Render through the existing Helmfile/Vals workflow and confirm:

- `url` is `https://argocd.quido.me`.
- `oidc.config` uses `https://id.quido.me`.
- The client secret is referenced through `argocd-secret`, not embedded in Git.
- The local administrator remains enabled.
- Group mappings are present in `argocd-rbac-cm`.
