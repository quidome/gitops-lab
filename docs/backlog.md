# Backlog

Open work, most important first. Changes link to their folder; small fixes are one line.

These items predate the product way of working. Each one becomes a change folder when it is picked up.

1. Check that the team database dump job ran on its own schedule: `lastScheduleTime` and `lastSuccessfulTime` after a night run (A1 of the closed change `done/2026-10-18-team-database-backup`; not checked at Close, covered by the alerts) – small
2. Off-site copy of the team database dumps (outside TrueNAS), so they are a full backup – from the team database backup
3. Own image with `pg_dump` and `age` for the backup job, instead of `apk add age` at each run – technical debt from the team database backup
4. Backups of the other databases (Vikunja and others), reusing the team backup pattern
5. [Notifications and outbound e-mail](../tasks/prd-notifications-and-email.md) ([tasks](../tasks/tasks-notifications-and-email.md)) – started, not yet a change
6. [Zigbee alerting through Home Assistant metrics](../tasks/prd-zigbee-alerting.md) – requirements only
7. [Move GitOps repositories from Codeberg to GitHub](../tasks/tasks-codeberg-to-github-migration.md) – task list only
8. [ArgoCD Vault auth hardening follow-up](tasks/2026-07-07-argocd-vault-auth-hardening.md) – notes only
