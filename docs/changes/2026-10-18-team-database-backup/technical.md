# Technical spec: Nightly backup of the team database

**Status**: done
**Size**: story
**Change**: docs/changes/2026-10-18-team-database-backup
**Date**: 2026-10-18

## Objective
Make a nightly, full, encrypted dump of the team PostgreSQL database on a TrueNAS share, with an
alert when it fails, written recovery steps and one tested restore, because the team data exists
only in this database and has no backup.

## Requirements summary
Technical change, no functional spec. The operator's request in a gitops-lab session: "here we
just ensure that we do full backups of the database". The encrypted player names (team
repository, backlog item 2 there) wait until after this change.

What is wrong now:
- The team database (StatefulSet `team-postgresql`, namespace `productivity`, one 10 GiB
  `truenas-iscsi` volume) has no backup. `applications/productivity/team/README.md` says backups
  are "owned by the homelab storage/backup process", but that process does not exist.
- Since team v0.3.0 the players, roles, trainings and attendance exist only in this database.
- `docs/vision.md`: no data loss is the first core value; backups are the first priority.

Expected result:
1. Each night at 02:30 Dutch time, a full logical dump of the database `team`
   (`pg_dump --format=custom`).
2. The plain dump exists only in memory inside the job pod. It is checked with
   `pg_restore --list`, then encrypted with age to the public key, and only the encrypted file is
   written to the share.
3. The share is a `truenas-nfs` volume. It keeps the newest 7 dumps (by count, never by age).
4. An alert (severity `critical`, so it reaches the operator through Pushover) fires when the
   last successful run is older than 26 hours, or when no successful run is known.
5. Recovery steps in `docs/product/team-database.md`, and one restore that was really done and
   checked (row counts).

Choices of the operator (2026-10-18):
- The dumps go to a TrueNAS share only, for now. TrueNAS is part of the platform, so these
  dumps are not yet a full "backup" in the meaning of `docs/language.md` (stored outside the
  platform). An off-site copy is a later change.
- Encryption with age. The public key is in git (`values.yaml`); the private key is kept only
  outside the platform (password manager and paper). It is not in Vault and not in the cluster.
- The `age` program comes from Alpine (`apk add age`) in an init container at each run
  (option A). Our own image is technical debt.
- Keep 7 dumps.
- Only the team database.

## Current state
- `applications/productivity/team/helmfile.yaml.gotmpl`: releases `team-postgresql`
  (`./postgresql-chart`), `team` (`./helm-chart`), `team-resources`. Vault values from
  `kv/productivity/team`.
- `postgresql-chart/`: StatefulSet (image `docker.io/library/postgres@sha256:3c5c88…`,
  PostgreSQL 16 Alpine, user 999, `POSTGRES_DB=team`, `POSTGRES_USER=team`, password file from
  Secret `team-postgresql`, key `password`), Service `team-postgresql` port 5432, headless
  Service, NetworkPolicy that allows only pods with `app.kubernetes.io/name: team` +
  `app.kubernetes.io/instance: team` on port 5432.
- Selector labels of the database: `app.kubernetes.io/name: team-postgresql`,
  `app.kubernetes.io/instance: team-postgresql` (`_helpers.tpl`, `team-postgresql.selectorLabels`).
  The Service selects pods with these labels.
- Storage classes: `truenas-iscsi` (default) and `truenas-nfs`, both `Retain`. Other non-root
  services write to `truenas-nfs` volumes (zigbee2mqtt, mosquitto).
- ArgoCD (`applications/applicationset.yaml`): no automatic sync, no self-heal; sync options
  `CreateNamespace`, `ServerSideApply`, `RespectIgnoreDifferences`.
- Prometheus: `ruleSelector: {}` (all PrometheusRules). Example rule:
  `infrastructure/observability/vault-monitoring/helm-chart/templates/prometheusrule.yaml`
  (labels `prometheus: kube-prometheus-stack`, `release: kube-prometheus-stack`).
  `kube_cronjob_status_last_successful_time` exists in the cluster (kube-state-metrics).
- Alertmanager (`infrastructure/observability/kube-prometheus-stack/values.yaml`): only
  `severity=critical` goes to the receiver `pushover`; other alerts only show in Karma.
- The team app runs its own nightly reading at 03:00 Dutch time.

## Steps

### Step 0: The age key pair (operator, by hand, once)
- **Goal**: a key pair whose private key exists only outside the platform.
- **Changes**: on the workstation, `nix shell nixpkgs#age -c age-keygen -o team-backup.key`.
  Store the file content in the password manager, and print it on paper. Delete the local file.
  Give the public key (`age1…`) to the developer for step 1.
- **Tests**: `age-keygen -y` on the stored private key gives the same public key.

### Step 1: The backup job
- **Goal**: the nightly encrypted dump on the share, with retention.
- **Changes** in `applications/productivity/team/postgresql-chart/`:
  - `values.yaml`, new block:
    ```yaml
    backup:
      enabled: true
      schedule: "30 2 * * *"
      timeZone: Europe/Amsterdam
      keep: 7
      ageRecipient: "age1…"          # public key from step 0
      installImage:
        repository: docker.io/library/alpine
        digest: sha256:…             # pinned multi-architecture digest
      storage:
        storageClass: truenas-nfs
        accessModes: [ReadWriteMany]
        size: 2Gi
      resources:                     # the in-memory dump counts against the memory limit
        requests: {cpu: 50m, memory: 256Mi}
        limits: {memory: 256Mi}
      alert:
        maxAgeHours: 26
    ```
  - `_helpers.tpl`: `team-postgresql.backupSelectorLabels` →
    `app.kubernetes.io/name: team-postgresql-backup`, `app.kubernetes.io/instance: {{ .Release.Name }}`;
    and `team-postgresql.backupLabels` (chart, version, managed-by, `component: backup`). The backup
    pod must never have the database selector labels.
  - `templates/backup-pvc.yaml`: PVC `team-postgresql-backup`, values from `backup.storage`,
    annotations `helm.sh/resource-policy: keep` and `argocd.argoproj.io/sync-options: Delete=false`.
  - `templates/backup-cronjob.yaml`: CronJob `team-postgresql-backup`:
    - `schedule`, `timeZone` from values; `concurrencyPolicy: Forbid`;
      `startingDeadlineSeconds: 3600`; `successfulJobsHistoryLimit: 3`;
      `failedJobsHistoryLimit: 3`.
    - Job: `backoffLimit: 1`, `activeDeadlineSeconds: 1800`; pod `restartPolicy: Never`,
      `automountServiceAccountToken: false`, `seccompProfile: RuntimeDefault`.
    - Init container `install-age`: the Alpine image by digest, `runAsUser: 0` (only this
      container), `allowPrivilegeEscalation: false`, command
      `apk add --no-cache age && cp /usr/bin/age /tools/age`. Small resources
      (`cpu: 10m`, memory 64Mi = limit).
    - Container `backup`: the same PostgreSQL image and digest as the StatefulSet
      (`.Values.image`), `runAsUser: 999`, `runAsGroup: 999`, `runAsNonRoot: true`,
      `readOnlyRootFilesystem: true`, drop all capabilities. Env: `PGHOST=team-postgresql`
      (fullname), `PGPORT`, `PGUSER`, `PGDATABASE` from `postgres.*`, `AGE_RECIPIENT`, `KEEP`.
      Script (`/bin/sh -c`):
      ```sh
      set -eu
      rm -f /backup/*.partial
      ts=$(date -u +%Y%m%dT%H%M%SZ)
      PGPASSWORD=$(cat /run/secrets/postgres/password) \
        pg_dump --format=custom --file=/work/team.dump
      pg_restore --list /work/team.dump >/dev/null
      /tools/age -r "$AGE_RECIPIENT" -o "/backup/team-$ts.dump.age.partial" /work/team.dump
      mv "/backup/team-$ts.dump.age.partial" "/backup/team-$ts.dump.age"
      ls -1 /backup/team-*.dump.age | sort -r | tail -n +$((KEEP + 1)) | xargs -r rm --
      echo "backup team-$ts.dump.age written"
      ```
      Logs carry the file name only, never data.
    - Volumes: `work` = `emptyDir {medium: Memory, sizeLimit: 128Mi}`, `tools` = `emptyDir`,
      `backup` = the PVC, `postgres-password` = Secret `team-postgresql` (mode 0440).
    - If test 6 shows that user 999 cannot write the new volume: add `fsGroup: 999` to the pod.
      If that is not enough, write it under Deviations before another fix.
  - `templates/networkpolicy.yaml`: a second `from` entry with `podSelector` on
    `team-postgresql.backupSelectorLabels` (same namespace), port 5432. The team app entry stays.
  - All new templates inside `{{- if .Values.backup.enabled }}`.
- **Tests**: 1–4 before the pull request; 6–8 after merge and sync (test 6 first).

### Step 2: The alert
- **Goal**: the operator gets a push message when the backup does not succeed.
- **Changes**: `templates/backup-prometheusrule.yaml` (inside `backup.enabled`), labels as the
  Vault monitoring rule, one group `team-database-backup`:
  - `TeamDatabaseBackupTooOld`:
    `time() - kube_cronjob_status_last_successful_time{namespace="productivity", cronjob="team-postgresql-backup"} > 26 * 3600`,
    `for: 15m` (hours from `backup.alert.maxAgeHours`).
  - `TeamDatabaseBackupMissing`:
    `absent(kube_cronjob_status_last_successful_time{namespace="productivity", cronjob="team-postgresql-backup"})`,
    `for: 26h` (so it does not fire between the deploy and the first night).
  - Both `severity: critical`, a summary, a description that says to read the job log
    (`kubectl logs -n productivity job/<job>`), and `runbook_url` to
    `docs/product/team-database.md` on GitHub.
- **Tests**: 5 before, 9 after.

### Step 3: Recovery steps and the tested restore
- **Goal**: written steps, shown to work once.
- **Changes**:
  - New `docs/product/team-database.md` (template `product-feature.md`): what is backed up,
    when, where (the PVC `team-postgresql-backup` and how to find its TrueNAS dataset: the PV
    name `pvc-…` from `kubectl get pvc`, written down in the document after step 1), the
    retention, the alert, where the private key is, and recovery steps for:
    1. **Restore into the running database**: copy the newest `.age` file from the share
       (a temporary pod that mounts the PVC, then `kubectl cp`; or from the TrueNAS dataset
       directly); `age -d -i <private key> -o team.dump <file>`;
       `kubectl scale deployment/team -n productivity --replicas=0`;
       `kubectl exec -i -n productivity team-postgresql-0 -- pg_restore --clean --if-exists -U team -d team < team.dump`;
       scale back to 1; check the app; delete `team.dump` from the workstation.
    2. **Lost cluster**: after the bootstrap and the sync of the team app (a new, empty
       database), take the file from the TrueNAS dataset, then the same steps.
    3. **Lost private key**: make a new key pair (step 0), change `backup.ageRecipient`; the old
       dumps cannot be read any more.
  - `applications/productivity/team/README.md`: replace the paragraph "Backups remain owned by
    the homelab storage/backup process…" with a short paragraph and a link to the product
    document.
  - The date and the result of test 10 go under Progress.
- **Tests**: 10, 11.

## Decisions
| Decision | Reason | Decision record? |
|----------|--------|------------------|
| Logical dump (`pg_dump --format=custom`), not volume snapshots | Independent of the storage; can be restored into any PostgreSQL 16; selective restore possible | At Close: "Database backups as an encrypted logical dump with age" |
| Encrypt with age to a public key; private key only outside the platform | A stolen dump or a broken-into cluster or Vault does not show the data | Same record |
| Plain dump only in a memory `emptyDir` | It never touches a disk | No |
| Retention by count (7), never by age | A long series of failures must not delete the good dumps | Same record |
| Write `.partial`, then rename | A half-written file never looks like a good dump | No |
| `age` installed from Alpine at each run (option A) | No new image pipeline now | No; technical debt |
| Everything in the existing PostgreSQL chart, behind `backup.enabled` | The chart owns the data; no new ArgoCD application | No |
| Alert severity `critical` | Only `critical` reaches the operator now | No |
| 01:30 Dutch time (was 02:30, changed after build review R1) | Not at the same time as the team app's nightly reading at 03:00, and outside 02:00–03:00, which the clock change skips or repeats | No |

## Not in scope
- An off-site copy outside TrueNAS (backlog).
- Our own image with `pg_dump` and `age` (backlog, technical debt).
- Backups of Vikunja and other databases (backlog).
- The encrypted player names (team repository, after this change).
- An automatic, repeated restore test.

## Test plan
- **Existing tests that must still pass**: from the repository root, `helm lint` and
  `helm template` of `postgresql-chart`, `helm-chart` and `resources`;
  `helmfile -f applications/productivity/team/helmfile.yaml.gotmpl lint` and `template`;
  ArgoCD sync of the team application and a healthy app.
- **New tests** (tools through `nix shell nixpkgs#kubeconform nixpkgs#prometheus nixpkgs#age`):
  1. `helm template` with `backup.enabled=false` is the same as the rendering on `main`.
  2. `helm template` with backup on passes `kubeconform -strict` (with the PrometheusRule CRD
     schema; or `-ignore-missing-schemas` for it, written down).
  3. In the rendered output, the backup pod labels do not match the database Service selector.
  4. `shellcheck` on the job script taken from the rendered CronJob.
  5. `promtool check rules` on the rule group.
  6. `kubectl create job --from=cronjob/team-postgresql-backup backup-test-1 -n productivity`:
     the job succeeds; the share has one `.age` file; no `.partial` and no plain dump.
  7. 8 runs in total: the share has exactly the 7 newest files.
  8. A failing run (a job with a wrong `PGHOST`): it fails, the 7 good files stay; the next good
     run removes the `.partial`.
  9. In the Prometheus query page, the `TooOld` expression with `> 60` gives a result.
  10. Decrypt the newest file on the workstation, restore it into a temporary PostgreSQL 16 pod
      in a scratch namespace, compare the row count of each table with the live database;
      delete the scratch namespace and the local plain dump.
  11. Decrypt with a wrong key: it fails.

## Compatibility and performance
- No change for the users of the team app. The database StatefulSet, its volume and Secret do
  not change (test 1 for the switch).
- The dump takes a few seconds for a database of a few MB, at night. The job uses at most
  256 MiB memory, including the in-memory dump; if the database grows past about 100 MB, raise
  `sizeLimit` and the memory together.
- The job needs the Alpine package mirror on the internet at 02:30.

## Progress
- [x] Step 0 – age key pair (operator), 2026-10-18: public key `age1m2x2…au74k` in `values.yaml`. The operator confirmed that the private key is in the password manager and on paper, and that `~/team-backup.key` is deleted.
- [x] Step 1 – backup job. PR #186, merged and synced 2026-10-18. Workstation checks and cluster tests 6–8 pass:
  - `helm lint` of `postgresql-chart`, `helm-chart`, `resources`: pass.
  - Test 1: rendering with `backup.enabled=false` is the same as before the change: pass.
  - Test 2: `kubeconform -strict`, Kubernetes 1.33: 7 resources valid.
  - Test 3: the backup pod labels do not match the database Service selector: pass.
  - Test 4: `shellcheck -s sh` on the rendered script: pass.
  - Extra, on the workstation with Docker: the rendered script, run with the same images, as user 999 with a read-only root file system, against a scratch database, writes one `.age` file; the name in the test data is not in the file; a wrong key cannot decrypt it; of 9 files the newest 7 stay and `.partial` files are removed.
  - Not run: `helmfile … lint`/`template` of the whole app needs Vault, which this workstation cannot reach. ArgoCD renders it at sync.
  - Cluster, 2026-10-18: ArgoCD `team` Synced and Healthy; CronJob, PVC `team-postgresql-backup` (`pvc-612723f9-2a7f-4889-9b7a-7b999638c420`, `truenas-nfs`, RWX) and the NetworkPolicy rule exist.
  - Test 6: a job started by hand completes in 14 s; the share has one `.age` file (29 KB, age header), no `.partial`, no plain dump. User 999 can write the NFS volume.
  - Test 7: 8 runs leave exactly the newest 7 files; the first one is deleted.
  - Test 8: a run with a wrong `PGHOST` fails (`could not translate host name`) and the 7 files stay. A wrong host makes `pg_dump` fail before any file is written, so a second failing job (`backoffLimit: 0`) writes a `.partial` and exits 1, the same as a crash during encryption. The `.partial` stays until the next good run removes it; 7 files stay. In the first try, the second attempt of the wrong-host job (`backoffLimit: 1`) removed the `.partial` before the check; this is the designed behaviour.
  - The test jobs are deleted. The 7 dumps from the tests stay on the share as real backups.
- [x] Step 2 – alert. PR #187, merged and synced 2026-10-18. Workstation checks, test 9 and the sync check pass:
  - `templates/backup-prometheusrule.yaml`: `TeamDatabaseBackupTooOld` (`for: 15m`) and `TeamDatabaseBackupMissing` (`for: 26h`), both `critical`, selector `namespace="productivity", cronjob="team-postgresql-backup"`. The `runbook_url` points to `docs/product/team-database.md`, which step 3 writes.
  - `helm lint`: pass. Test 1 again: with `backup.enabled=false` the rendering is the same as before the change.
  - Test 5: `promtool check rules` (Prometheus 3.12, `nixpkgs#prometheus.cli`): 2 rules, success.
  - `kubeconform -strict` with the CRD schemas of the datreeio CRDs catalog: 8 resources valid.
  - Test 9, against the live Prometheus before the merge: the `TooOld` expression with `> 60` gives a result (last success 101 s before); with `> 26 * 3600` and `absent(…)` there is no result, so neither alert fires now.
  - After the sync (2026-10-18, 08:16:50 UTC): Prometheus loaded the group `team-database-backup` (interval 60 s); both rules have health `ok`, state `inactive`, no error; no `TeamDatabaseBackup*` alert is active.
- [x] Step 3 – recovery steps and tested restore, 2026-10-18:
  - New `docs/product/team-database.md`: the database, the nightly backup, where the dumps are (NFS share `172.16.40.64:/mnt/datapool/k8s/nfs/volumes/pvc-612723f9-2a7f-4889-9b7a-7b999638c420`), the key, the alerts, errors and limits, and the recovery steps (get, decrypt, restore into the running database, after a lost cluster, a lost key, clean up). The team README paragraph "Backups remain owned by the homelab storage/backup process…" is replaced by a short paragraph and a link.
  - Test 10, done by following the document: step 1 (temporary read-only pod, `kubectl cp`) copied `team-20261018T081212Z.dump.age`; the operator decrypted it with the private key from the password manager (step 2); the command of step 3a restored it into a temporary PostgreSQL 16 pod (same image) in the scratch namespace `team-restore-test`: `pg_restore` exit 0. All 13 tables have the same row count as the live database (for example `players` 14, `player_roles` 14, `games` 71, `absences` 2), the 6 migrations are all successful, and an MD5 checksum of the full content of each table is equal for all 13 tables. The scratch namespace and the local files (encrypted and plain dump) are deleted.
  - Test 11 on the real cluster dump: a new, wrong key gives `no identity matched any of the recipients`, exit 1, no output.
  - Not run on live data: the restore into the running database (3a) and the lost-cluster steps (3b). They use the same `pg_restore` command; the document says so.
- [x] All checks pass (workstation checks of steps 1 and 2; cluster tests 6–11). Not run: the full `helmfile template`, which needs Vault from the workstation; ArgoCD rendered and synced it without errors.

## Deviations
- 2026-10-18, step 1: the pod has `fsGroup: 999` (with `fsGroupChangePolicy: OnRootMismatch`) from the start, not only as the fallback for the NFS write test. Reason: the password file is mounted with mode 0440, and without `fsGroup` user 999 cannot read it (the database pod has `fsGroup: 999` for the same reason).
- 2026-10-18, step 1: `backup.installImage` also has `tag: "3.24.2"`, and the image is `repository:tag@digest`. Reason: the spec says Renovate updates the digest, and the Renovate Helm values manager needs a tag for that.
- 2026-10-18, step 1: the delete line uses `printf '%s\n' /backup/team-*.dump.age` instead of `ls -1 …` (shellcheck SC2012). Same result, tested.
- 2026-10-18, after build review R1: the schedule is `30 1 * * *` (01:30), not 02:30. Reason: 02:30 does not exist on the night the clocks go forward, so the job skipped that night and the age alert fired (47 h gap). At 01:30 the longest normal gap is 25 h, under the 26 h limit.
- 2026-10-18, after build review R2: recovery step 3a restores into a new database `team_restore` and then swaps the names, instead of `pg_restore --clean` on the running database. Reason: `--clean` fails when a later migration added a table that refers to a table in the dump.
- 2026-10-18, after accept review A2: the job checks the dump with `pg_restore --file=/dev/null` instead of `pg_restore --list`. Reason: `--list` reads only the table of contents and passes a cut-off dump (tested).
- None from a functional spec (technical change). The original request of this `/design` was the
encrypted player names; the operator replaced it in Phase 0 with this backup (see the log in
`change.md`).

## Review findings

### Build review, 2026-10-18 (fresh agent, `/review build`)

Input: mode `build` and this change folder. The arguments had nothing else. Scope: the branch
`docs/team-database-recovery` against `main` only holds step 3 (product doc, README, progress).
Steps 1 and 2 were already merged in #186 and #187, so I also reviewed those files as they are on
`main` (`postgresql-chart/values.yaml`, `_helpers.tpl`, `templates/backup-*.yaml`,
`templates/networkpolicy.yaml`). Read: the diff, `change.md`, this document, `docs/architecture.md`
(still an empty template), `docs/decisions/` (empty), `AGENTS.md`, `docs/vision.md`,
`docs/language.md`, `docs/backlog.md`. Nothing rebuilt that already exists: a search for
`pg_dump|kind: CronJob|velero|volsync|volumesnapshot` in `infrastructure/` and `applications/`
finds no other backup pattern.

**R1 – Each spring the job skips a night and a false critical alert fires (medium).** The
schedule `30 2 * * *` in `Europe/Amsterdam` falls in the hour that does not exist on the last Sunday
of March, and in the hour that occurs twice on the last Sunday of October. Checked by a run: I fed
the schedule to `github.com/robfig/cron/v3` v3.0.1 (the parser the Kubernetes CronJob controller uses)
in a scratch program. Result: runs on 2027-03-27 and then 2027-03-29, with no run on 2027-03-28 (47 h
gap), and two runs on 2026-10-25 (00:30 and 01:30 UTC). The 47 h gap is more than
`maxAgeHours: 26`, so `TeamDatabaseBackupTooOld` sends a critical Pushover message each March
(around 05:45 local time on the Sunday), and the operator learns to ignore this alert. The double
run in October only costs one day of history (7 dumps then cover 6 days). Fix: pick a time outside
02:00–03:00 that is still not 03:00 (for example `30 1 * * *` or `30 3 * * *`), and change the
"02:30" in the product doc, the README and the decision table. The spec chose 02:30; the spec did
not see this.

**R2 – Restore with `--clean` fails when the live schema is newer than the dump (medium).** Recovery
step 3a says that the app image "must be the same version as at the time of the dump, or newer",
and 3b restores into a database that the *current* app image has already migrated. But
`pg_restore --clean --if-exists` only drops the objects that are in the dump, without `CASCADE`. When a
later migration adds a table with a foreign key to a table in the dump (the team migrations
`0003`–`0006` already use `REFERENCES`, so this is the normal pattern), `DROP TABLE` of the
referenced table fails, `--exit-on-error` stops, and `--single-transaction` rolls back. The result
is safe (nothing changes) but the restore does not work, and the document gives no next step. How
checked: a trace of the commands and PostgreSQL's drop behaviour; `grep -il references
migrations/*` in `quidome/team` finds 4 of 6 migrations with foreign keys. Not run: my scratch
reproduction in Docker was blocked by a permission check, so this is not reproduced. Test 10
restored into an *empty* database, so the `--clean` path over existing tables was never exercised
(see R3). Fix (docs only): in 3a and 3b, empty the database first (for example
`dropdb`/`createdb` as user `team` inside `team-postgresql-0` while the app is at 0 replicas, or
`DROP SCHEMA public CASCADE; CREATE SCHEMA public`), then `pg_restore` without `--clean`; and in 3b
scale the app to 0 before the restore. Then try 3a once on a scratch database that already has the
schema.

**R3 – The progress claims are true, but one is broader than what was tested (low).** I reran:
test 1 (rendering with `backup.enabled=false` equals the chart at `8886d60^`: identical), `helm lint`
(pass), test 2 (`kubeconform -strict`, Kubernetes 1.33, datreeio CRD catalog: 8 valid), test 4
(`shellcheck -s sh` on the script from the rendered CronJob: pass), test 5 (`promtool check rules`:
2 rules, success). In the cluster (read-only `kubectl get`): CronJob and PVC
`pvc-612723f9-…` exist, `lastSuccessfulTime` 2026-10-18T08:12:15Z, ArgoCD `team` Synced and Healthy.
Tests 6–8, 10, 11 and the post-sync rule check: not checked (they need exec or the private key). The
claim "Not run on live data: 3a and 3b. They use the same `pg_restore` command" is true about the
command, but the part that 3a adds over test 10 – dropping existing objects – is exactly what was not
run (R2). No test was found that cannot fail; test 9 and the `absent(…)` check show that the label
selector matches the live metric.

**R4 – The product doc and README call the dumps a "backup", against `docs/language.md` (low).**
The word list: a backup is "stored outside the platform" and "has been shown to restore". The
platform includes storage, so TrueNAS is inside it, and this document says so ("these dumps are not
yet a full backup in the meaning of `docs/language.md`"). `docs/product/team-database.md` still
says "The nightly backup makes sure that … a lost cluster does not lose them", and the README says
"What is backed up", although it also says the dumps are on TrueNAS only. The product doc's "Errors and limits" says the dumps are on TrueNAS
only, but a reader of the vision ("every service that keeps data has a backup") can take the team
database as done. Checked by reading. Fix: say "nightly dump" (or keep the names of objects such
as the CronJob and the alerts) and add one line under Purpose that this is not yet a backup in the
word-list meaning until the off-site copy (backlog item 2) exists. The technical names
(`team-postgresql-backup`, `TeamDatabaseBackup*`) can stay.

**R5 – Small sibling and doc points (low).**
- The recovery pod in step 1 uses `alpine:3.24.2` by tag only, while the chart pins the digest;
  Renovate does not update Markdown, so the doc will drift from `backup.installImage`. Checked by
  reading `renovate.json5` (managers `helm-values`, `helmfile`, `helmv3`, `kubernetes` on `*.yaml`).
  Suggest: no tag in the doc ("the image in `backup.installImage`"), or accept the drift.
- The `install-age` init container runs as root with all default capabilities; it does not drop
  any. `apk add` and `cp` as root need few or none of them. Checked by reading the rendered
  CronJob. Not tried with `drop: [ALL]`. Hardening only; the operator accepted option A.
- The product doc points to `docs/changes/done/2026-10-18-team-database-backup/`, which exists only
  after `/close`. True after Close; nothing to do if Close moves the folder.
- The working tree of this branch also holds the unrelated, uncommitted product-workflow setup
  (renames from `docs/specs/`, `docs/stories/`, `tasks/` and `docs/adrs/`, the new `AGENTS.md`
  section "Way of working", `docs/vision.md` and others). Checked with `git status`. Keep it out of
  the step 3 commit or pull request, or make it a separate commit with its own message.
- Docs made false by the diff: none found. `AGENTS.md`, `README.md` and `docs/vision.md` do not
  claim anything about the team backup; the vision's "Rough: backups … are not yet a solved and
  checked part of the platform" stays true (R4). The decision record and the "Known technical debt"
  line for `apk add age` (backlog item 3) are planned for Close; `docs/architecture.md` is still the
  empty template.

**Rules in `AGENTS.md`:** resources follow the rule (CPU requests only, memory request = limit) in
both containers and in the recovery pod; the backup PVC is RWX on NFS with `Retain` and
`resource-policy: keep` plus `Delete=false`; no new Vault paths; no HTTPRoute. No breach found.

**Verdict:** no blocker. R1 and R2 should be fixed before Close (R1 is a one-line value change plus
docs; R2 is a docs change and one scratch try). R3–R5 are notes.

**Builder's answers (2026-10-18), branch `fix/team-database-backup-review`:**
- R1 – fixed: `backup.schedule` is `30 1 * * *` with a comment why; product doc, README and the decision table say 01:30. The longest normal gap is now 25 h (October, Sunday to Monday), under the 26 h limit. Sync check: open until the PR is merged.
- R2 – fixed and tested. First reproduced in the scratch namespace `team-restore-test`: a database with the dump's schema plus a table of a "later migration" with a foreign key to `players`; the old command `pg_restore --clean --if-exists --single-transaction --exit-on-error` stopped with `cannot drop constraint players_pkey … Use DROP ... CASCADE`, exit 1, nothing changed. Then the new 3a steps against the same database (one row changed first): `createdb team_restore`, `pg_restore --single-transaction --exit-on-error` into it, `ALTER DATABASE … RENAME` swap: all ok, and the restored `team` equals the live database in the MD5 checksum of all 13 tables; `dropdb team_old` ok. A broken dump into `team_restore` fails and `team` keeps its 14 players. The dump for this test was streamed from the live `pg_dump` into the scratch pod's memory volume (never on the workstation disk); decryption was already shown by test 10. 3b now says that 3a scales the app to 0 first. Scratch namespace deleted.
- R3 – no change needed: the claim in the product doc now says what was tested and what was not.
- R4 – fixed: the product doc and README say "nightly dump", and the Purpose says that the dumps are not yet a backup in the meaning of `docs/language.md` until the off-site copy exists. Object names (`team-postgresql-backup`, `TeamDatabaseBackup*`, "backup volume") stay.
- R5.1 – fixed: step 1 of the recovery steps reads the image from `backup.installImage` in `values.yaml` with `yq` (tag and digest), so it cannot drift. Checked with `kubectl run --dry-run=client`: image `alpine:3.24.2@sha256:294b68…`, user 999, PVC `team-postgresql-backup`.
- R5.2 – not fixed: `apk add` needs root to install the package, the container runs for a few seconds, and it has no service account token. The real fix is the own image (backlog item 3), which removes the init container.
- R5.3 – fixed: the doc names the change folder and says it is in `docs/changes/` or in `docs/changes/done/` after Close.
- R5.4 – no change needed: the step 1, 2 and 3 commits held only their own files; the workflow setup stays uncommitted.
- Checks after the fixes: `helm lint` pass; test 1 (backup off equals before) pass; `kubeconform -strict` with CRD schemas: 8 valid.

### Acceptance review, 2026-10-18 (fresh agent, `/review accept`)

Input: mode `accept` and this change folder; the arguments had nothing else. Technical change, so
the yardstick is the Objective, the Requirements summary (expected results 1–5 and the operator's
choices) and `change.md`. Read: `change.md`, this document up to Progress, the result (the diff
`8886d60^..HEAD` for `applications/productivity/team/` and `docs/product/team-database.md`, plus
the uncommitted tree), `docs/vision.md`, `docs/language.md`, `docs/backlog.md`. Deviations and the
build review were read only after the points below were formed. Checks run: `helm template` of
`postgresql-chart` on this branch (schedule `30 1 * * *`, both alert expressions as specified);
read-only `kubectl get` in `productivity` (CronJob, PVC `pvc-612723f9-…` RWX `truenas-nfs`,
NetworkPolicy, PrometheusRule; live rule expressions equal the rendered ones). Not checked: the
share content, decrypting and restoring (need exec or the private key); I rely on the Progress
record for tests 6–11.

**A1 – Expected result 1, the nightly full dump: faithful adaptation.** Built as
`pg_dump --format=custom` of `team`, at 01:30 instead of 02:30 Dutch time. The change is the right
reading of the intent ("each night"): 02:30 does not exist one night a year, and the alert would
then fire falsely. 01:30 is outside the shifted hour, still before the team app's 03:00 reading;
the October gap of 25 h stays under the 26 h limit. Checked by reading the rendered CronJob and by
reasoning about the clock change. **Open, not a deviation:** the live CronJob still says
`30 2 * * *` (this branch is not merged) and `LAST SCHEDULE` is `<none>`: every success so far is a
job started by hand. Checked with `kubectl get cronjob`. Before Close: merge, sync, and see one
scheduled night run succeed (and `lastSuccessfulTime` move).

**A2 – Expected result 2, plain dump only in memory, checked, then encrypted: faithful.** Memory
`emptyDir` (128Mi), `pg_restore --list`, `age -r` to the public key, `.partial` then rename; only
the `.age` file reaches the share. Checked by reading the rendered script. Note (neutral drift in
the doc): the product doc says "A damaged dump makes the run fail here" about `pg_restore --list`.
`--list` reads the header and the table of contents, not the data blocks; a dump that is cut off
in its data is caught by the exit code of `pg_dump` (`set -eu`), not by `--list`. Checked by trace,
not run. Suggest: "A dump with a damaged header or table of contents makes the run fail here", or
leave as is.

**A3 – Expected result 3, `truenas-nfs` share, newest 7 by count: faithful.** Retention runs only
after a good rename, sorts by the UTC timestamp in the name, never by age. PVC keeps through Helm
and ArgoCD (`resource-policy: keep`, `Delete=false`, `Retain`). Checked by reading; test 7 and 8 in
Progress show it in the cluster.

**A4 – Expected result 4, critical alert for too old or missing: faithful.** Both rules are
`critical` (the only severity that reaches Pushover), `TooOld` at 26 h + 15 m, `Missing` with
`for: 26h`. The live rule matches the rendering. Note for the operator, not a deviation: one failed
night pages at about 03:45 local time (26 h after 01:30, plus 15 m). That is what "critical" asks
for; if a page at night is not wanted, Pushover quiet hours or a later schedule are the levers, not
this change.

**A5 – Expected result 5, recovery steps and one real, checked restore: faithful adaptation.**
`docs/product/team-database.md` has get, decrypt, restore into the running database, lost cluster,
lost key and clean up. Test 10 is a real restore of a real encrypted dump from the share, decrypted
with the real private key, with row counts (and checksums) of all 13 tables. Step 3a changed after
test 10 (from `pg_restore --clean` to restore into `team_restore` plus a rename swap). This serves
the intent better: the old command would not have worked after a later migration, which is
exactly the lost-cluster case (3b restores into an already migrated database). The new 3a was
tried on a scratch database with a newer schema; the decrypt step was shown by test 10. So the full
path is shown in two parts, not in one run; the product doc says this honestly. Not checked by me
(needs exec and the key).

**A6 – Restore step 3a: one small gap (low, neutral).** `kubectl scale … --replicas=0` returns
before the app pod is gone. If the pod still holds a connection when the rename runs,
`ALTER DATABASE team RENAME` fails with "being accessed by other users". The result is safe (both
renames fail, `team` keeps its data), but the doc gives no hint. Checked by trace, not run.
Suggest: after the scale to 0, wait for the pod to go
(`kubectl wait --for=delete pod -l app.kubernetes.io/name=team -n productivity --timeout=120s`),
and in the failure list: "if the rename says the database is in use, wait and run it again".

**A7 – Operator's choices: all kept.** TrueNAS only, with the off-site copy in the backlog (item 2);
age with the private key only outside the platform (the public key is in `values.yaml`; no key in
Vault or the cluster found in the diff); `apk add age` at each run, with the own image in the
backlog (item 3); keep 7; only the team database (other databases are backlog item 4). Checked by
reading the diff and `docs/backlog.md`.

**A8 – Language: faithful.** The product doc and README now say "nightly dump" and state that the
dumps are not yet a backup in the meaning of `docs/language.md` until the off-site copy exists.
This keeps the vision's "Rough: backups … are not yet a solved and checked part" true, and does not
let the operator read the first core value as done for the team data. The change title and object
names still say "backup"; acceptable as names. Checked by reading.

**Deviations, read after the above:** all five agree with what I found. `fsGroup: 999` from the
start, the image tag next to the digest, and `printf` instead of `ls` are faithful adaptations
with no effect on the intent. The 01:30 schedule (A1) and the restore swap (A5) are faithful
adaptations that serve the intent better than the spec. No concerning deviation.

**Verdict: accepted with notes.** What was built is what was meant: a nightly, full, encrypted dump
on the TrueNAS share, kept by count, with a critical alert, written recovery steps and one real,
checked restore. Before Close: merge and sync this branch and see one scheduled night run succeed
(A1). Optional doc touches: A2 wording, A6 wait step.

**Builder's answers to the accept review (2026-10-18), branch `fix/team-database-backup-review` (PR #189):**
- A1 – open until merge and sync: the CronJob must show `30 1 * * *`, and one run on its own schedule must succeed before Close.
  - 2026-10-18, after PR #189 merged and synced (`f8bc8fe`, `team` Synced and Healthy): the live CronJob has `30 1 * * *`, `Europe/Amsterdam`, and the check `pg_restore --file=/dev/null`. A job started by hand with it completed in 7 s (`team-20261018T084046Z.dump.age`). `lastScheduleTime` is still empty: the first run on the schedule is 2026-10-19 01:30.
  - 2026-10-18, operator: not checked before Close. The operator cannot check the first scheduled run in the coming week and accepts the change on the alerts: if the run of 2026-10-19 01:30 (or a later one) fails, `TeamDatabaseBackupTooOld` sends a critical push message (at about 03:45 for a first failed night). The operator reopens the change when needed.
- A2 – fixed: the job checks the dump with `pg_restore --file=/dev/null` (reads all data) instead of `pg_restore --list`. Tested on the workstation with the same PostgreSQL image and a 4.4 MB dump: the good dump passes both checks (exit 0); the dump cut off at 2/3 passes `--list` (exit 0) but fails the new check (exit 1, `could not read from input file: end of file`). The product doc says so. Recorded under Deviations.
- A6 – fixed: step 3a waits for the app pod to be gone (`kubectl wait --for=delete pod -l app.kubernetes.io/name=team,app.kubernetes.io/instance=team`) before the restore, and says what to do if the rename still finds the database in use.
- A3, A4, A5, A7, A8 – no change needed.
