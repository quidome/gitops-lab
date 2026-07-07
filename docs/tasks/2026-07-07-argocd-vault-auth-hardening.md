# ArgoCD Vault auth hardening follow-up

## Context

On 2026-07-07, many ArgoCD applications showed `Unknown` sync status while remaining `Healthy`.

Root cause:
- ArgoCD repo-server Helmfile plugin could not render manifests with Vals
- the shared Vault token from `gitops/vault-token` had become invalid/revoked
- affected apps failed comparison with `permission denied` / `invalid token`

## Immediate remediation

- rotate the `vals-reader` Vault token
- update secret `gitops/vault-token`
- restart `deployment/argocd-repo-server -n gitops`
- verify affected apps return from `Unknown`

## Follow-up work

Current design depends on a single static shared Vault token injected into ArgoCD.
This creates a large blast radius and recurring operational breakage.

Investigate and implement a more durable auth model for ArgoCD + Vals, preferably one of:

1. Vault Kubernetes auth for repo-server / plugin
2. Vault AppRole with controlled rotation
3. explicit token renewal automation

## Acceptance criteria

- document chosen auth model
- remove or reduce dependency on manually rotated static token
- verify ArgoCD can render Vault-backed apps after pod restart without manual token replacement
- update `infrastructure/security/vault/VALS-SETUP.md` accordingly
