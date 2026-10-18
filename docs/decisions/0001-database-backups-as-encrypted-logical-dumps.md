# 0001 – Database backups as encrypted logical dumps

**Status**: valid
**Date**: 2026-10-18
**Change**: [docs/changes/done/2026-10-18-team-database-backup](../changes/done/2026-10-18-team-database-backup/change.md)

## Context
The team database (PostgreSQL, one `truenas-iscsi` volume) had no backup, and since team v0.3.0
its players and attendance exist only there. The data is personal data of children. The vision
puts no data loss first, and the platform runs on one operator who must be able to restore
without the platform (a lost cluster, a lost Vault). Other services with PostgreSQL (Vikunja) will
need the same, so the way of working must be reusable.

## Decision
A database is backed up by a nightly logical dump, made and encrypted inside the cluster:

- `pg_dump --format=custom` of the whole database, by a CronJob in the database's own chart.
- The plain dump exists only in a memory volume of the job pod. A check that reads the whole dump
  (`pg_restore --file=/dev/null`) must pass before anything is written.
- The dump is encrypted with age to a **public key that is in git**. The **private key is kept only
  outside the platform** (password manager and paper), never in git, Vault or the cluster.
- The encrypted file is written as `.partial` and renamed when complete, to an NFS volume that Helm
  and ArgoCD never delete.
- Old dumps are deleted **by count** (keep the newest N), never by age.
- A restore goes into a **new database, and then the names are swapped**; never
  `pg_restore --clean` on the running database. The old data stays until the operator has checked
  the app.
- A critical alert fires when the last successful run is older than about a day plus two hours, or
  unknown.

## Options considered
| Option | For | Against |
|--------|-----|---------|
| Logical dump (chosen) | Independent of the storage; restores into any PostgreSQL of the same major version; small; a restore can be checked table by table | Needs a job, a key and a restore procedure per database |
| TrueNAS snapshots of the database volume | No job in the cluster | A snapshot of a running database is not guaranteed consistent; lives on the same TrueNAS; restore needs TrueNAS and the CSI driver; not readable outside the platform |
| age with the private key outside the platform (chosen) | A stolen dump, or a broken-into cluster or Vault, shows no data; a restore needs no part of the platform | The operator must keep the key safe; a lost key makes the old dumps useless |
| A symmetric key in Vault | Simpler; one value | Anyone with Vault access reads the dumps; a lost platform also loses the key |
| Retention by age | Simple to reason about | A long series of failed runs deletes all good dumps |
| `pg_restore --clean` on the running database | One command | Fails when a later migration added a table that refers to a table in the dump (reproduced); no old data to go back to |
| Install `age` at each run from Alpine (chosen for now) | No image to build and maintain | Needs the internet at night; the init container runs as root (technical debt) |
| Our own image with `pg_dump` and `age` | No download; no root container | A new image pipeline |

## Consequences
- Each new database with data gets the same parts: the CronJob, the NFS volume, a NetworkPolicy
  entry, the alert and a product document with recovery steps (see `docs/architecture.md`,
  "Database backups").
- The operator keeps one private key per backup set outside the platform, and checks once that the
  stored copy gives the same public key.
- The schedule must avoid 02:00–03:00 Dutch time: that hour is skipped or repeated when the clock
  changes, and a skipped night fires the age alert.
- While the dumps are only on TrueNAS, they are not yet a backup in the meaning of
  `docs/language.md`. An off-site copy is a separate change.
