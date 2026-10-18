# Team database

What the team database and its nightly dump do **now**, for the operator. Updated at each /close that
changes it.

## Purpose
The team app (the youth team coordinator tool, source in `quidome/team`) keeps its data in one
PostgreSQL database: the players, their roles, the trainings, the attendance, the game schedule
and the sessions. Since team v0.3.0 the players and attendance exist only in this database. The
nightly dump makes sure that a broken database, a deleted volume or a lost cluster does not lose
them.

The dumps are on TrueNAS, which is part of the platform. So they are not yet a backup in the
meaning of `docs/language.md` (stored outside the platform). They become one when the off-site
copy exists (backlog).

## Behaviour

### The database
- StatefulSet `team-postgresql` in namespace `productivity`, PostgreSQL 16 (Alpine image pinned
  by digest), database and role `team`.
- Data on a 10 GiB `truenas-iscsi` volume (`data-team-postgresql-0`, Retain policy).
- Only the team app pods and the backup job pods can connect (NetworkPolicy `team-postgresql`).
- Chart: `applications/productivity/team/postgresql-chart/`. Deployed by ArgoCD (application
  `team`); the README of the team deployment has the configuration and the secrets.

### The nightly dump
- CronJob `team-postgresql-backup`, each night at 01:30 Dutch time: before the team app's own
  nightly reading at 03:00, and outside the hour 02:00–03:00 that the clock change skips or
  repeats.
- One run:
  1. An init container (Alpine, pinned) installs `age` (a file encryption tool) with `apk`.
  2. `pg_dump --format=custom` makes a full dump of the database `team` into memory in the pod.
     The plain dump never touches a disk.
  3. `pg_restore --list` reads the dump. A damaged dump makes the run fail here.
  4. `age` encrypts the dump to the backup public key. The file is written as
     `team-<UTC date-time>.dump.age.partial` and then renamed to `team-<UTC date-time>.dump.age`.
  5. All dumps except the newest 7 are deleted (by count, never by age, so a series of failed
     runs keeps the last good dumps). A `.partial` file of a failed run is deleted at the start of
     the next run.
- If a run fails, Kubernetes tries once more. The last 3 good and 3 failed jobs stay for their
  logs.

### Where the dumps are
- PVC `team-postgresql-backup` (2 GiB, `truenas-nfs`, Retain policy; Helm and ArgoCD never delete
  it).
- On TrueNAS: NFS share `172.16.40.64:/mnt/datapool/k8s/nfs/volumes/pvc-612723f9-2a7f-4889-9b7a-7b999638c420`
  (dataset `datapool/k8s/nfs/volumes/pvc-612723f9-2a7f-4889-9b7a-7b999638c420`). This path stays
  the same while the PVC exists. A rebuilt cluster gets a new, empty backup volume; the old dumps
  stay in this dataset.

### The key
- The dumps are encrypted with age to the public key
  `age1m2x2uzs9dtsvzk3e223spnckkx7qalqyfzqpzyc7er5aka29dqts6au74k` (`backup.ageRecipient` in the
  chart values).
- The private key is kept only outside the platform: in the operator's password manager
  ("team backup age key") and on paper. It is not in git, Vault or the cluster. Without it, the
  dumps cannot be read.

### The alerts
Both are `critical`, so they reach the operator through Pushover:
- `TeamDatabaseBackupTooOld`: the last successful run is more than 26 hours old.
- `TeamDatabaseBackupMissing`: Prometheus has known no successful run for 26 hours (the job never
  succeeded, or the CronJob is gone).

## Errors and limits
- **An alert fires.** Read the log of the last job:
  ```bash
  kubectl get jobs -n productivity -l app.kubernetes.io/name=team-postgresql-backup
  kubectl logs -n productivity job/<job> --all-containers
  ```
  Known causes:
  - `install-age` fails: the Alpine package mirror was not reachable at night. Run the dump job
    again by hand (below) when the internet works.
  - `pg_dump` cannot connect: the database is down, or the NetworkPolicy changed.
  - The write fails: the share is full or TrueNAS is down.

  After the fix, run the dump job once by hand and check that the alert stops:
  ```bash
  kubectl create job --from=cronjob/team-postgresql-backup backup-manual-$(date +%s) -n productivity
  ```
- **The dumps are only on TrueNAS.** TrueNAS also holds the database volume, so a lost TrueNAS
  loses both. An off-site copy is in the backlog. Until then, these dumps protect against a broken
  database, a deleted volume and a lost cluster, but not against a lost TrueNAS.
- **The job needs the internet** at 01:30 to install `age`.
- **At most 7 days back.** A problem that is seen after more than 7 nights cannot be undone from
  the dumps.
- The recovery steps were tested on 2026-10-18 in a scratch namespace: the full path (copy,
  decrypt, restore) into an empty database, and the steps of 3a against a database with a newer
  schema than the dump (see the change folder `2026-10-18-team-database-backup` in
  `docs/changes/`, or in `docs/changes/done/` after it is closed). They were not run against the
  live database.

## Recovery steps

You need: `kubectl` access to the cluster, `age` on the workstation
(`nix shell nixpkgs#age`), and the private key from the password manager.

### 1. Get a dump

While the cluster runs, start a temporary pod that mounts the share read-only. Run this from the
repository root; it uses the pinned image of `backup.installImage`:
```bash
IMG=$(yq '.backup.installImage | .repository + ":" + .tag + "@" + .digest' \
  applications/productivity/team/postgresql-chart/values.yaml)
kubectl run backup-copy -n productivity --restart=Never --image="$IMG" --overrides='
{"spec":{"automountServiceAccountToken":false,
 "securityContext":{"runAsUser":999,"runAsGroup":999,"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"backup-copy","image":"'"$IMG"'","command":["sleep","3600"],
  "securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},
  "resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"memory":"32Mi"}},
  "volumeMounts":[{"name":"backup","mountPath":"/backup","readOnly":true}]}],
 "volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"team-postgresql-backup","readOnly":true}}]}}'
kubectl wait --for=condition=ready pod/backup-copy -n productivity
kubectl exec -n productivity backup-copy -- ls -1 /backup          # newest is last
kubectl cp productivity/backup-copy:/backup/<file> ./<file>
kubectl delete pod backup-copy -n productivity
```
When the cluster is gone: copy the file from the TrueNAS dataset above (TrueNAS shell, or mount
the NFS share from a host that the share allows).

### 2. Decrypt it
```bash
umask 077
# paste the private key from the password manager into team-backup.key
age -d -i team-backup.key -o team.dump <file>
rm team-backup.key
```
A wrong key gives `no identity matched any of the recipients`.

### 3a. Restore into the running database
This replaces all data in the database `team` with the dump. The dump goes into a new database
`team_restore` first; then the two databases swap names. The old data stays as `team_old` until
you have checked the app. Do not run this at 01:30, when the dump job runs.
```bash
kubectl scale deployment/team -n productivity --replicas=0
kubectl exec -n productivity team-postgresql-0 -- createdb -U team -O team team_restore
kubectl exec -i -n productivity team-postgresql-0 -- \
  pg_restore --single-transaction --exit-on-error -U team -d team_restore < team.dump
kubectl exec -n productivity team-postgresql-0 -- psql -U team -d postgres \
  -c 'ALTER DATABASE team RENAME TO team_old' -c 'ALTER DATABASE team_restore RENAME TO team'
kubectl scale deployment/team -n productivity --replicas=1
```
Check the app: log in, open the team page and the attendance page. Then delete the old data:
```bash
kubectl exec -n productivity team-postgresql-0 -- dropdb -U team team_old
```
- If `pg_restore` fails, nothing has changed: delete `team_restore` with `dropdb` and scale the
  app back to 1.
- If the app is wrong after the swap, scale it to 0, swap back (rename `team` to `team_restore`,
  then `team_old` to `team`), and scale it to 1.
- Do not use `pg_restore --clean` on the running database: when a later migration added a table
  that refers to a table in the dump, the drop fails and the restore stops.
- The dump includes the table of applied migrations. An app image of the same version as at the
  time of the dump, or newer, runs its missing migrations when it starts. The ArgoCD application
  has no automatic sync, so the scale to 0 stays until you scale back.

### 3b. Restore after a lost cluster
1. Bootstrap the platform (`README.md`) and sync the `team` application. It makes a new, empty
   database, and the team app runs its migrations.
2. Get the dump from the old TrueNAS dataset (step 1, "when the cluster is gone") and decrypt it
   (step 2).
3. Restore it as in 3a (it scales the app to 0 first).
4. Run the dump job once by hand, so the new backup volume has a good dump at once.

### 3c. The private key is lost
1. Make a new key pair: `nix shell nixpkgs#age -c age-keygen -o team-backup.key`. Store the
   private key in the password manager and on paper; delete the local file.
2. Put the new public key in `backup.ageRecipient` in
   `applications/productivity/team/postgresql-chart/values.yaml`, merge and sync.
3. Run the dump job once by hand. The old dumps cannot be read any more; they are deleted after 7
   nights.

### 4. Clean up
Delete `team.dump` and the `.age` file from the workstation (`rm`). The plain dump contains the
names of the players.

## Interface
Chart values (`applications/productivity/team/postgresql-chart/values.yaml`, block `backup`):

| Value | Now | Meaning |
|---|---|---|
| `enabled` | `true` | Turns the job, the volume, the NetworkPolicy rule and the alerts on or off |
| `schedule`, `timeZone` | `30 1 * * *`, `Europe/Amsterdam` | When the job runs |
| `keep` | `7` | Number of newest dumps kept |
| `ageRecipient` | `age1m2x2…au74k` | The public key the dumps are encrypted to |
| `installImage` | Alpine `3.24.2`, pinned digest | The image that installs `age` |
| `storage` | `truenas-nfs`, `ReadWriteMany`, `2Gi` | The backup volume |
| `resources` | 50m CPU, 256Mi memory | Includes the in-memory dump |
| `alert.maxAgeHours` | `26` | Age limit of the last successful run |
