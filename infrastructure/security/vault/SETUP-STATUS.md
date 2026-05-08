# Vault Setup Status

**Last Updated**: 2026-05-08

## Current State

✅ Vault is the active secrets backend in this repo.

- Vault runs in `security` namespace
- Helmfile + Vals is used for deploy-time secret injection
- ArgoCD runs in `gitops` namespace
- External Secrets can use the `vault` `ClusterSecretStore` for runtime sync use cases

## Operational References

- Setup and operations: `infrastructure/security/vault/README.md`
- Vals integration: `infrastructure/security/vault/VALS-SETUP.md`
- Vault + Vals architecture and conventions: `AGENTS.md`

## Notes

This file now serves as a lightweight status marker. Historical migration notes were removed to avoid drift with the current Vault-first architecture.
