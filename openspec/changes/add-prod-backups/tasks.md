# Tasks: Production Backups

## 1. Backblaze B2 setup (user action, one-time)
- [ ] 1.1 Sign up at https://www.backblaze.com/b2/sign-up.html (no card needed for free tier).
- [ ] 1.2 Create a bucket: **name** `jenkinz-mealie-backup`, **Files in Bucket are** `Private`, **Default Encryption** `Enabled (SSE-B2)`, **Object Lock** `Disabled`. Region defaults to US-West; fine for our purposes.
- [ ] 1.3 Create an **application key** scoped to that bucket only: Account → App Keys → "Add a New Application Key". Name: `mealie-prod-restic`. Allow access to a single bucket: `jenkinz-mealie-backup`. Type of Access: `Read and Write`. Duration: empty (no expiry — rotate annually). Click Create.
- [ ] 1.4 Save to 1Password under three entries (or one multi-field entry):
  - `Backblaze – B2 keyID (mealie-prod)`
  - `Backblaze – B2 applicationKey (mealie-prod)`
  - `Mealie – restic repo password (prod)` ← generated separately with `openssl rand -base64 32`

## 2. Chart updates
- [ ] 2.1 Add `backup:` section to `helm/mealie/values.yaml` with sensible defaults (disabled; schedule `0 3 * * *`; retention 7d/4w/12m; 128Mi/512Mi resources; `existingSecret: backup-credentials`).
- [ ] 2.2 Create `helm/mealie/templates/backup-cronjob.yaml` — `batch/v1` CronJob, guarded by `.Values.backup.enabled`. The single container uses `postgres:15-alpine` and runs an inline script that installs restic via `apk`, pipes `pg_dump` → `restic backup --stdin`, then `restic forget --prune` with the retention policy. `envFrom` the `backup-credentials` Secret. `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 3`, `concurrencyPolicy: Forbid`.
- [ ] 2.3 Verify dev render: with `backup.enabled: false` (the default), no CronJob is emitted.
- [ ] 2.4 Verify prod render: with `backup.enabled: true`, CronJob manifest emits with the correct schedule + secret ref + retention flags.

## 3. prod.yaml
- [ ] 3.1 Set `backup.enabled: true` and `backup.b2Bucket: "jenkinz-mealie-backup"` in `helm/values/prod.yaml`.

## 4. Justfile recipes
- [ ] 4.1 Add `just backup-bootstrap`: verifies env vars `B2_KEY_ID`, `B2_APP_KEY`, `RESTIC_PASSWORD`, `POSTGRES_PASSWORD` are set; verifies prod kubeconfig exists; creates/updates the `backup-credentials` Secret in the `mealie` namespace via `kubectl apply --dry-run=client -o yaml | kubectl apply -f -` pattern; idempotent. Also: on first run, runs `restic init` in a one-shot Pod so the repo exists on B2.
- [ ] 4.2 Add `just backup-now`: `kubectl -n mealie create job mealie-backup-manual-$(date +%s) --from=cronjob/mealie-backup`. Watches the Job to completion and tails logs.
- [ ] 4.3 Add `just restore-drill`: shells out to `scripts/restore-drill.sh`.

## 5. Restore drill
- [ ] 5.1 `k8s/backups/restore-drill.yaml` — a Pod manifest with a `postgres:15-alpine` container + an initContainer that installs restic, fetches the latest snapshot via `restic dump latest mealie.sql`, and pipes it into `psql` against localhost.
- [ ] 5.2 `scripts/restore-drill.sh`:
  - Generates scratch namespace name (`mealie-restore-drill-<ts>`).
  - Copies `backup-credentials` Secret from `mealie` → scratch namespace.
  - Applies `restore-drill.yaml` into scratch namespace with the generated name.
  - `kubectl wait --for=condition=ready` on the Pod (timeout 5m).
  - Exec `psql -U postgres -d mealie -c "SELECT count(*) FROM users;"` — parse the number; fail if `== 0` (empty restore means something's wrong).
  - On success: `kubectl delete namespace <scratch-ns>` and exit 0.
  - On any failure: leave the namespace in place for inspection, print `kubectl -n <ns> describe / logs` hints, exit non-zero.
- [ ] 5.3 `chmod +x scripts/restore-drill.sh`.

## 6. Documentation
- [ ] 6.1 `k8s/backups/README.md`: B2 signup + bucket + app-key walkthrough with exact permission scopes; secrets generation (with `openssl rand` commands); `backup-bootstrap` → `backup-now` → `restore-drill` flow; retention semantics; manual-restore procedure for when a real restore is needed (not the drill); troubleshooting (stale credentials, B2 rate limits, restic repo-locked).
- [ ] 6.2 Update root `README.md` → Production Deploy section to include the `just backup-bootstrap` one-time step after `just deploy-prod`.

## 7. Verification
- [ ] 7.1 `just backup-bootstrap` succeeds; `kubectl -n mealie get secret backup-credentials` exists with all 8 keys.
- [ ] 7.2 `restic snapshots` (via a one-shot Pod using the secret) connects to B2 and lists (empty list on first run is fine).
- [ ] 7.3 `just backup-now` completes successfully; `kubectl -n mealie get jobs` shows the manual Job as `Complete 1/1`; restic snapshot count is now 1.
- [ ] 7.4 `just restore-drill` — scratch namespace spun up, latest snapshot restored into a temp postgres, user count query returns > 0, namespace cleaned up. Total time < 3 minutes.
- [ ] 7.5 Day-after verification: check that the 03:00 UTC scheduled CronJob ran and created a second snapshot. `kubectl -n mealie get jobs` shows a `mealie-backup-<hash>` Job marked Complete.
- [ ] 7.6 Retention works: leave the cronjob running for ~2 weeks, confirm old snapshots are pruned per policy. (This one's a long-tail verification — document in the runbook, don't block phase 6 archive.)

## 8. Open decisions (resolved)
- [x] 8.1 Backup tool: **restic** (encryption + dedup + retention in one binary; B2-native).
- [x] 8.2 Image: `postgres:15-alpine` with `restic` installed via `apk` at run time. Trade-off: 2s apk overhead on each run, but avoids maintaining a custom image.
- [x] 8.3 Schedule: daily 03:00 UTC. Quiet hours for UK/EU users.
- [x] 8.4 Retention: 7 daily / 4 weekly / 12 monthly (restic `forget --keep-*` flags). Reasonable storage footprint and history depth for family data.
- [x] 8.5 Secret management: single `backup-credentials` Secret, bootstrapped by `just backup-bootstrap` from env vars out of 1Password. Consistent with phase 5's no-sealed-secrets approach.
- [x] 8.6 Restore drill: scratch namespace + temp Postgres + real `psql` query verification. A dry "snapshot exists" check isn't enough — phase 6's acceptance is "we can actually get the data back."
