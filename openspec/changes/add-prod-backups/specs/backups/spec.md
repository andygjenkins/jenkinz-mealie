# Backups Specification

## ADDED Requirements

### Requirement: Scheduled Daily Backups
A CronJob in the `mealie` namespace SHALL run daily and back up the PostgreSQL
database to Backblaze B2 via restic.

#### Scenario: CronJob exists with correct schedule
- **WHEN** the chart is rendered with `backup.enabled: true`
- **THEN** a `batch/v1` CronJob named `mealie-backup` is emitted
- **AND** its schedule is `0 3 * * *` (03:00 UTC daily, or the configured value)
- **AND** `concurrencyPolicy` is `Forbid`

#### Scenario: CronJob runs and creates a restic snapshot
- **WHEN** the CronJob fires (scheduled or via `just backup-now`)
- **THEN** the resulting Job completes with exit code 0
- **AND** a new restic snapshot is present in the B2 repository

### Requirement: Encrypted, Deduplicated Off-Site Storage
Backups SHALL be encrypted at rest and stored outside the Hetzner VPS, so the
loss of the VPS and its disk does not affect recoverability.

#### Scenario: Backups are encrypted with a repo password
- **WHEN** the restic repository is inspected without the `RESTIC_PASSWORD`
- **THEN** no recognizable SQL or plaintext is visible in the B2 bucket
- **AND** `restic snapshots` without the password fails with a decryption error

#### Scenario: Backups land in Backblaze B2
- **WHEN** a backup Job completes
- **THEN** objects are present in the `jenkinz-mealie-backup` B2 bucket under
  the `mealie/` prefix (restic's internal layout)

### Requirement: Retention Policy Enforced
Old backups SHALL be pruned according to a grandfather-father-son retention
policy to prevent unbounded storage growth.

#### Scenario: Retention flags applied after each backup
- **WHEN** a backup Job completes
- **THEN** `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12
  --prune` runs in the same Job
- **AND** snapshots older than the policy are removed from B2

### Requirement: Credentials Sourced From a Single Secret
The system SHALL consolidate all backup credentials (B2 keys, restic password,
database password, and database connection info) into one Kubernetes Secret
named `backup-credentials` in the `mealie` namespace, created by
`just backup-bootstrap`.

#### Scenario: Bootstrap creates the secret
- **WHEN** a developer runs `just backup-bootstrap` with env vars `B2_KEY_ID`,
  `B2_APP_KEY`, `RESTIC_PASSWORD`, and `POSTGRES_PASSWORD` all set
- **THEN** a Secret named `backup-credentials` exists in the `mealie` namespace
- **AND** it contains keys for B2 account id + key, restic password + repository,
  Postgres host/user/db/password

#### Scenario: Bootstrap fails fast without credentials
- **WHEN** `just backup-bootstrap` runs with any of the required env vars unset
- **THEN** the command exits non-zero with a message naming the missing
  variables
- **AND** no Secret is created or modified

### Requirement: On-Demand Backup
The repository SHALL provide a way to trigger an ad-hoc backup without waiting
for the scheduled CronJob.

#### Scenario: Manual backup via justfile
- **WHEN** a developer runs `just backup-now`
- **THEN** a new Job is spawned from the CronJob template (using `kubectl
  create job --from=cronjob/mealie-backup`)
- **AND** the Job runs to completion
- **AND** logs are tailed to stdout for visibility

### Requirement: Tested End-to-End Restore
The repository SHALL provide a restore drill that validates backups are actually
restorable. This is the acceptance criterion for phase 6; the CronJob itself is
not.

#### Scenario: Restore drill into a scratch namespace
- **WHEN** a developer runs `just restore-drill` against a prod cluster with at
  least one existing backup snapshot
- **THEN** a scratch namespace is created
- **AND** a temporary PostgreSQL is brought up in the scratch namespace
- **AND** the latest restic snapshot is fetched and restored into that Postgres
- **AND** a test query (`SELECT count(*) FROM users;`) returns a non-zero value
- **AND** the scratch namespace is deleted
- **AND** the command exits 0

#### Scenario: Drill fails visibly on bad state
- **WHEN** the drill fails at any step (secret missing, no snapshots, restore
  error, zero-row query)
- **THEN** the scratch namespace is **not** deleted (left for inspection)
- **AND** the command prints the namespace name and hints for `kubectl describe`
  / `kubectl logs`
- **AND** exits non-zero

### Requirement: Runbook for Backups and Restore
A runbook SHALL document the setup, operational flows, and the manual restore
procedure for real recovery scenarios.

#### Scenario: Runbook covers the full lifecycle
- **WHEN** a developer opens `k8s/backups/README.md`
- **THEN** the document describes: B2 signup, bucket + application-key creation
  with correct scopes, secret generation and 1Password entries, bootstrap /
  backup-now / restore-drill commands, retention semantics, and the manual
  restore-to-production procedure for a real data-loss event
