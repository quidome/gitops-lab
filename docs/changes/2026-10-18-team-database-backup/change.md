---
title: Nightly backup of the team database
type: technical
stage: implement
closure: review build + accept
created: 2026-10-18
---

# Nightly backup of the team database

A nightly full dump of the team PostgreSQL database, encrypted with age in the cluster, written
to a TrueNAS share with retention, with an alert when it fails, written recovery steps and one
tested restore. Since team v0.3.0 the players and attendance exist only in this database, and no
backup covers it.

## Log
| Date | Stage | Note |
|------|-------|------|
| 2026-10-18 | design | created from `/design technical: …`. The first request (encrypted player names) belongs to the team repository and waits until after this backup (operator). Answers in Phase 0: TrueNAS share only for now (an off-site copy is a later change), encryption with age, a Prometheus alert is in scope, only the team database. |
| 2026-10-18 | implement | technical.md approved; closure `review build` (new data path and a NetworkPolicy change next to the only copy of the team data). Next: `/implement docs/changes/2026-10-18-team-database-backup`. |
| 2026-10-18 | implement | Step 1 built. Closure raised to `review build + accept`: the spec missed that the password file needs `fsGroup` (a surprise), see Deviations. Only the operator can lower it. |
| 2026-10-18 | implement | Build review: no blocker; R1 (schedule in the skipped hour) and R2 (restore with `--clean`) fixed with two deviations, R5.2 not fixed. Closure stays `review build + accept` (already the highest). |
