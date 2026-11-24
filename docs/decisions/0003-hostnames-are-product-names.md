# 0003 – Hostnames are product names

**Status**: valid
**Date**: 2026-11-24

## Context
Each service already has a product name in its Helm release, its service document, its Vault path
and its resource names. Some hostnames used the same name (`grafana`, `vault`, `argocd`, `hass`),
others the job of the service (`alerts` for Karma, `tasks` for Vikunja, `id` for Pocket ID, `rss`
for FreshRSS, `flix` for Jellyfin). The operator had to translate between the two names, and job
names overlap: `id` and `auth` both mean "login", `alerts` and `alerts-sso` are one job.

A job name lets a product be replaced without a new URL. With one operator this happens seldom,
and a redirect from the old hostname is a small change.

## Decision
- The main hostname of a service is its product name, the same as the release and the service
  document: `karma.quido.me`, `vikunja.quido.me`, `pocket-id.quido.me`.
- A service that household users open directly can also have a short job name as a second
  hostname on the same route (for example `flix` for Jellyfin). The service document lists both.
- Services that only the operator uses get no job name.
- When a hostname changes, the old hostname redirects to the new one for some time, so that
  bookmarks keep working. Login callback URLs registered in Pocket ID change in the same change.

## Consequences
- Existing job-name hostnames are renamed one service per change (tasks in Vikunja).
- Renaming Pocket ID changes the address that all single sign-on clients trust (the OIDC issuer).
  All clients must change at the same time, so this rename is the last and the largest.
- Renaming Vikunja changes the server in `.veans.yml` in this repository and in `gitops-apps`, and
  each workstation must trust the new server once.
