# Production Backups Runbook

Daily encrypted off-site backups of the Mealie PostgreSQL database to Backblaze
B2, with a tested restore path.

**What's backed up**: full `pg_dump` of the `mealie` database, piped through
`restic` for encryption, compression, and deduplication, and stored on
Backblaze B2.

**What's NOT backed up** (these live in git or 1Password, re-derivable):
- Helm chart + values
- Mealie session key / Postgres password (1Password)
- Uploaded recipe images stored at `/app/data` inside the Mealie pod *(TODO:
  consider a second restic target for the PVC in a future change if image
  uploads become heavy)*.

## One-time setup

### 1. Backblaze B2 account + bucket + application key

1. Sign up at https://www.backblaze.com/b2/sign-up.html — free tier gives 10 GB
   storage and 1 GB/day download, no card required.
2. Create a bucket:
   - Name: `jenkinz-mealie-backup`
   - Files in Bucket are: **Private**
   - Default Encryption: **Enabled (SSE-B2)**
   - Object Lock: **Disabled**
   - Region: US-West (default; fine for our purposes)
3. Create a scoped application key: Account → App Keys → "Add a New
   Application Key":
   - Name: `mealie-prod-restic`
   - Allow access to Bucket: `jenkinz-mealie-backup` (**not** "All Buckets")
   - Type of Access: **Read and Write**
   - Expiry: leave empty (rotate annually via a calendar reminder)
4. **Copy both values shown** (`keyID` and `applicationKey`) — `applicationKey`
   is only shown once.

### 2. Generate the restic repo password

```bash
openssl rand -base64 32
```

### 3. Save to 1Password

Three 1Password entries (or one multi-field item):

| Entry | Value |
|---|---|
| `Backblaze – B2 keyID (mealie-prod)` | the `keyID` from step 1.3 |
| `Backblaze – B2 applicationKey (mealie-prod)` | the `applicationKey` from step 1.3 |
| `Mealie – restic repo password (prod)` | output of `openssl rand -base64 32` |

### 4. Bootstrap the Kubernetes Secret

From the repo root, with kubeconfig pointing at prod (Tailscale up):

```bash
export KUBECONFIG=~/.kube/mealie-prod.yaml

export B2_KEY_ID="$(op read 'op://Personal/Backblaze – B2 keyID (mealie-prod)/credential')"
export B2_APP_KEY="$(op read 'op://Personal/Backblaze – B2 applicationKey (mealie-prod)/credential')"
export RESTIC_PASSWORD="$(op read 'op://Personal/Mealie – restic repo password (prod)/credential')"
export POSTGRES_PASSWORD="$(op read 'op://Personal/Mealie – Postgres password (prod)/credential')"

just backup-bootstrap
```

This creates/updates the `backup-credentials` Secret in the `mealie` namespace
with all eight keys needed by the CronJob and restore-drill.

(If you don't use the 1Password CLI, paste the values into `export` commands
manually. Just don't commit them anywhere.)

## Day-to-day operations

```bash
# Ad-hoc backup (spawns a Job from the CronJob template, tails logs).
just backup-now

# Verify end-to-end restore. ~2-3 minutes.
just restore-drill
```

The scheduled CronJob runs automatically at **03:00 UTC daily** —
confirm the next morning with:

```bash
kubectl -n mealie get jobs
kubectl -n mealie logs job/mealie-backup-<hash>
```

## Retention

Applied automatically after every successful backup via
`restic forget --keep-daily N --keep-weekly N --keep-monthly N --prune`:

| Policy | Count |
|---|---|
| Daily | 7 |
| Weekly | 4 |
| Monthly | 12 |

Rough storage footprint at Mealie scale: <100 MB in B2 well into year 1.

## Real restore (for actual data loss, not the drill)

If you've lost prod data and need to restore the latest good snapshot into the
live Mealie cluster:

```bash
export KUBECONFIG=~/.kube/mealie-prod.yaml

# 1. Stop Mealie so it isn't writing while we swap the DB out from under it.
kubectl -n mealie scale deployment mealie --replicas=0

# 2. Drop and recreate the database (destructive — obviously only do this
#    when restoring).
POD=$(kubectl -n mealie get pod -l app.kubernetes.io/name=mealie-postgres -o name)
kubectl -n mealie exec -it "$POD" -- psql -U mealie -d postgres -c 'DROP DATABASE mealie;'
kubectl -n mealie exec -it "$POD" -- psql -U mealie -d postgres -c 'CREATE DATABASE mealie;'

# 3. Run an ad-hoc "restore" pod that streams the latest snapshot into the
#    live Postgres. (Reuses the backup-credentials Secret.)
cat <<'EOF' | kubectl -n mealie apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: restic-restore-live
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: postgres:15-alpine
      envFrom:
        - secretRef:
            name: backup-credentials
      command:
        - /bin/sh
        - -c
        - |
          apk add --no-cache restic >/dev/null
          restic dump latest mealie.sql | \
            PGPASSWORD="$POSTGRES_PASSWORD" psql \
              -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q
          echo "✓ Restore complete."
EOF

kubectl -n mealie wait --for=condition=ready pod/restic-restore-live --timeout=60s || true
kubectl -n mealie logs -f pod/restic-restore-live
kubectl -n mealie delete pod restic-restore-live

# 4. Bring Mealie back up.
kubectl -n mealie scale deployment mealie --replicas=1

# 5. Smoke test.
just smoke-url https://mealie.jenkinz.net
```

If you need a snapshot *other than* the latest, first list them and pick one:

```bash
kubectl -n mealie run -it --rm restic-ls --image=postgres:15-alpine --restart=Never \
  --env-from=secretRef.name=backup-credentials \
  -- sh -c 'apk add --no-cache restic >/dev/null && restic snapshots'
```

Then swap `restic dump latest mealie.sql` for `restic dump <snapshot-id>
mealie.sql` in the restore pod spec.

## Troubleshooting

**`just backup-bootstrap` fails with missing env vars**
→ Export all four (`B2_KEY_ID`, `B2_APP_KEY`, `RESTIC_PASSWORD`,
`POSTGRES_PASSWORD`) from 1Password and retry.

**Backup job fails with `Fatal: ... unable to open config file`**
→ First run on an empty bucket — restic needs `restic init` to create its
repo. The CronJob's inline script handles this (`restic snapshots || restic
init`), but if it races (rare), run `just backup-now` which will init on
first try.

**`restic: unable to authenticate with B2`**
→ The B2 keyID or applicationKey is wrong/revoked. Regenerate in the Backblaze
console, update 1Password, re-run `just backup-bootstrap`.

**`restore-drill` fails at the query step (0 users)**
→ The dump restored but didn't populate the users table. This is a real red
flag — inspect `kubectl -n <drill-ns> logs job/restore-drill` and the drill
pod logs. The snapshot may be corrupted (unlikely with restic) or the dump
flags differ from what `psql -f` expects.

**`restic: snapshot is locked`**
→ A backup was interrupted or another client is writing. Unlock with:
```
restic unlock
```
(Run via a one-shot pod with the backup-credentials envs. Only do this if
you're sure no backup is currently in progress.)
