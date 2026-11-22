# Architecture: gitops-lab

How the platform is built **now**. Update it in the same pull request as the change that makes
it outdated. The reasons for choices are in `docs/decisions/`.

## Purpose
A home lab platform that runs services for the household and is a lab where the operator learns
to run a platform well. Almost all of the house works when the cluster is down: short outages are
acceptable, lost data is not.

Priorities, in order: backups, alerting, other operational work (hardening, updates, recovery
steps).

## Principles
- Git is the truth. Changes go through git and ArgoCD; routine work needs no manual steps on the cluster.
- Data safety comes before uptime.
- Manual work is acceptable for the bootstrap, and it must be written down. Exception: managing
  guests and the settings of third-party services that git cannot reach (for example the Tailscale
  access policy and public DNS) may be manual, if each step and its current value are written in
  the service document.
- A service is not done until it has a backup (if it keeps data), alerting, and recovery steps in
  `docs/services/`.
- Keep it simple enough for one operator to run.
- Nothing is open to the public internet. Guests reach only the shared services, only over
  Tailscale, and only through the shared entry. Accounts and permissions inside a service are a
  separate matter of each service.

## Overview
A k3s cluster on NixOS. ArgoCD deploys every infrastructure part (`infrastructure/<realm>/<part>`) and every service (`applications/<realm>/<service>`) from git with Helmfile; secrets come from Vault at deploy time; data volumes are on TrueNAS (`truenas-iscsi`, `truenas-nfs`). `AGENTS.md` has the layout and the rules for each part. Parts below are described only when a change needed it.

## Layers and modules
| Part | Responsibility | Depends on |
|------|----------------|------------|
| `applications/productivity/team/postgresql-chart` | The team database (StatefulSet `team-postgresql`) and its nightly encrypted dump (CronJob, NFS volume, alert) | `truenas-iscsi`, `truenas-nfs`, kube-prometheus-stack |

## Patterns to follow
### Database backups (decision 0001)
For each PostgreSQL database that keeps data. Reference: `applications/productivity/team/postgresql-chart`
(`templates/backup-*.yaml`) and `docs/services/team-database.md`.
- All parts in the database's own chart, behind `backup.enabled`; with it off, the rendering is the same as without the parts.
- A CronJob with `concurrencyPolicy: Forbid`, a deadline and one retry. Schedule in Dutch time (`timeZone: Europe/Amsterdam`), **never between 02:00 and 03:00** (the clock change skips or repeats that hour).
- The backup container uses the same PostgreSQL image and digest as the database, as a non-root user with a read-only root file system; `fsGroup` so it can read the password file and write the share.
- `pg_dump --format=custom` into an `emptyDir` with `medium: Memory`; check with `pg_restore --file=/dev/null` (reads all data; `--list` reads only the table of contents); `age -r <public key>` to `<name>.partial`, then rename.
- Delete old dumps by count (`keep`), never by age. Remove `.partial` files at the start of a run.
- The dumps on a `truenas-nfs` PVC with `helm.sh/resource-policy: keep` and `argocd.argoproj.io/sync-options: Delete=false`.
- The backup pods have their own labels (`<name>-backup`), which never match the database selector, and their own NetworkPolicy entry.
- A PrometheusRule with two `critical` alerts on `kube_cronjob_status_last_successful_time`: too old (`for: 15m`) and `absent` (with `for:` as long as the age limit).
- The public key in `values.yaml`; the private key only outside the platform.
- Restore: into a new database, then swap the names (`ALTER DATABASE … RENAME`); the app at 0 replicas and its pod gone first. Never `pg_restore --clean` on the running database.
- A service document with recovery steps, and one restore that was really done and checked before the change is merged.

## Known technical debt
- The database backup job installs `age` from the Alpine package mirror at each run, in an init container that runs as root (`backup.installImage`). It needs the internet at night. Fix: our own image with `pg_dump` and `age` (Vikunja).
- The team database dumps are on TrueNAS only, the same system as the database volume, so they are not yet a backup in the meaning of `docs/language.md`. Fix: an off-site copy (Vikunja).
