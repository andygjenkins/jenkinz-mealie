# Change: Production Backups (Phase 6)

## Why

Mealie is now live in prod with real (eventually-family) data. A single-node
Hetzner CX33 with a PVC on local-path-provisioner has exactly one copy of the
database. A disk failure, a botched Helm upgrade, an accidental `kubectl delete`
in the wrong namespace, or a ransomware scenario on the VPS all have the same
outcome right now: total data loss.

Phase 6 fixes that by adding a daily encrypted, deduplicated backup to Backblaze
B2, with a tested restore path so we actually know the backups work.

The approved-plan acceptance criterion for this phase is not "the CronJob
exists." It is **`just restore-drill` succeeds end-to-end** — a latest snapshot
pulled from B2, restored into a scratch PostgreSQL, validated by querying real
rows.

## What Changes

### Chart

- Add a `backup:` section to `helm/mealie/values.yaml` with:
  ```yaml
  backup:
    enabled: false
    schedule: "0 3 * * *"     # daily 03:00 UTC
    image:
      repository: postgres
      tag: "15-alpine"        # has pg_dump; restic added via apk at run time
    b2Bucket: ""               # e.g. "jenkinz-mealie-backup"
    resticPath: "mealie"      # prefix inside the bucket
    retention:
      daily: 7
      weekly: 4
      monthly: 12
    resources:
      requests: { memory: "128Mi", cpu: "50m" }
      limits:   { memory: "512Mi", cpu: "500m" }
    # Existing Secret consumed for B2 + restic + DB creds; created by
    # `just backup-bootstrap`.
    existingSecret: "backup-credentials"
  ```

- Add `helm/mealie/templates/backup-cronjob.yaml` — guarded by
  `.Values.backup.enabled`. The CronJob runs a single container that:
  1. `apk add --no-cache restic` (~2s)
  2. Pipes `pg_dump` → `restic backup --stdin --stdin-filename mealie.sql --tag daily`
  3. `restic forget --keep-daily … --keep-weekly … --keep-monthly … --prune`

- Wire prod to enable it: `helm/values/prod.yaml` sets `backup.enabled: true` and
  `backup.b2Bucket: "jenkinz-mealie-backup"`.

### Secrets

A single `backup-credentials` Secret in the `mealie` namespace holds:

| Key | Source |
|---|---|
| `B2_ACCOUNT_ID` | B2 application-key **keyID** |
| `B2_ACCOUNT_KEY` | B2 application-key **applicationKey** |
| `RESTIC_PASSWORD` | generated `openssl rand -base64 32`, saved to 1Password |
| `RESTIC_REPOSITORY` | `b2:jenkinz-mealie-backup:mealie` (derived) |
| `POSTGRES_HOST` | `mealie-postgres` (service name) |
| `POSTGRES_USER` | `mealie` |
| `POSTGRES_DB` | `mealie` |
| `POSTGRES_PASSWORD` | same value used in the existing `mealie` Secret (from 1Password) |

### Justfile

- `just backup-bootstrap` — creates/updates the `backup-credentials` Secret from
  env vars (`B2_KEY_ID`, `B2_APP_KEY`, `RESTIC_PASSWORD`, `POSTGRES_PASSWORD`).
  Fails fast if any is missing. Idempotent.
- `just backup-now` — triggers an ad-hoc backup by spawning a Job from the
  CronJob template (`kubectl create job mealie-backup-manual-<ts> --from=cronjob/mealie-backup`).
  Useful for verifying the backup pipeline before waiting for 03:00.
- `just restore-drill` — runs `scripts/restore-drill.sh` (see below).

### Restore drill

- `scripts/restore-drill.sh`: orchestrates end-to-end validation:
  1. Creates a scratch namespace `mealie-restore-drill-<timestamp>`.
  2. Copies `backup-credentials` Secret into the scratch namespace.
  3. Applies `k8s/backups/restore-drill.yaml` — a Pod running
     `postgres:15-alpine` (empty DB) + an initContainer/sidecar that installs
     restic, pulls the latest snapshot, and pipes it into the empty Postgres
     via `psql`.
  4. Waits for the Pod to reach `Ready`.
  5. Exec's a query: `SELECT count(*) FROM users;` — asserts > 0 rows.
  6. Deletes the scratch namespace.
  7. Exits 0 on success, non-zero with diagnostic output on any step failure.

### Documentation

- `k8s/backups/README.md`: full runbook — B2 signup, bucket + application-key
  creation with least-privilege scopes, secret generation + 1Password entries,
  bootstrap flow, retention semantics, manual-restore procedure (for when
  you really need a restore — not the drill).

## Out of Scope (deferred)

- **Hetzner-level snapshots** — a different mechanism; restic-to-B2 is more
  portable and encryption-first. Could add later if we want belt-and-braces.
- **Cross-region replication inside B2** — overkill for family Mealie; B2
  already has 99.999999999% durability.
- **Application-level exports** (Mealie's backup zip format) — restic of the
  DB captures everything; Mealie's zip format is nice for cross-install
  portability but isn't the recovery mechanism.
- **PITR / continuous archiving** (pgBackRest, wal-g). Daily dumps are the
  right granularity for a family app (RPO = 24h is fine).
- **Automated restore scheduling** — the drill is on-demand. A weekly
  automated drill is a nice-to-have add-on if we want extra confidence.

## Impact

- New capability spec: `backups`.
- New files:
  - `helm/mealie/templates/backup-cronjob.yaml`
  - `k8s/backups/README.md`
  - `k8s/backups/restore-drill.yaml`
  - `scripts/restore-drill.sh`
- Touches:
  - `helm/mealie/values.yaml` (new `backup:` section, defaults)
  - `helm/values/prod.yaml` (enable backups, set bucket)
  - `justfile` (three new recipes)
- New cloud dependencies: Backblaze B2 account + bucket + application key.
- Cost impact: B2 free tier = 10 GB storage + 1 GB/day download. Mealie DB
  dumps are small (tens of MB each, deduped via restic). Realistic monthly
  cost: **<$0.10** well into year 1.
