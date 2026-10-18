# Technical spec: Nightly backup of the team database

**Status**: in progress
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
| 02:30 Dutch time | Not at the same time as the team app's nightly reading at 03:00 | No |

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
- [ ] Step 2 – alert. Built 2026-10-18; workstation checks and test 9 pass, the sync check is open:
  - `templates/backup-prometheusrule.yaml`: `TeamDatabaseBackupTooOld` (`for: 15m`) and `TeamDatabaseBackupMissing` (`for: 26h`), both `critical`, selector `namespace="productivity", cronjob="team-postgresql-backup"`. The `runbook_url` points to `docs/product/team-database.md`, which step 3 writes.
  - `helm lint`: pass. Test 1 again: with `backup.enabled=false` the rendering is the same as before the change.
  - Test 5: `promtool check rules` (Prometheus 3.12, `nixpkgs#prometheus.cli`): 2 rules, success.
  - `kubeconform -strict` with the CRD schemas of the datreeio CRDs catalog: 8 resources valid.
  - Test 9, against the live Prometheus before the merge: the `TooOld` expression with `> 60` gives a result (last success 101 s before); with `> 26 * 3600` and `absent(…)` there is no result, so neither alert fires now.
- [ ] Step 3 – recovery steps and tested restore
- [ ] All checks pass

## Deviations
- 2026-10-18, step 1: the pod has `fsGroup: 999` (with `fsGroupChangePolicy: OnRootMismatch`) from the start, not only as the fallback for the NFS write test. Reason: the password file is mounted with mode 0440, and without `fsGroup` user 999 cannot read it (the database pod has `fsGroup: 999` for the same reason).
- 2026-10-18, step 1: `backup.installImage` also has `tag: "3.24.2"`, and the image is `repository:tag@digest`. Reason: the spec says Renovate updates the digest, and the Renovate Helm values manager needs a tag for that.
- 2026-10-18, step 1: the delete line uses `printf '%s\n' /backup/team-*.dump.age` instead of `ls -1 …` (shellcheck SC2012). Same result, tested.
- None from a functional spec (technical change). The original request of this `/design` was the
encrypted player names; the operator replaced it in Phase 0 with this backup (see the log in
`change.md`).

## Review findings
