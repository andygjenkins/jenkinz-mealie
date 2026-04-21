# Tasks: Add Deployment Smoke Tests

## 1. Smoke-test script
- [x] 1.1 Create `scripts/smoke-test.sh`: accepts a base URL (default `http://localhost:9000`), env vars for credentials, `set -euo pipefail`.
- [x] 1.2 Check 1 — API health: `GET /api/app/about` returns HTTP 200 and JSON with a `version` field.
- [x] 1.3 Check 2 — Authentication: `POST /api/auth/token` with test credentials returns a non-empty `access_token`.
- [x] 1.4 Check 3 — DB-backed read: authenticated `GET /api/users/self` returns HTTP 200 and the caller's email.
- [x] 1.5 On any failure: print the failing check + curl output + non-zero exit. On success: print a green summary and exit 0.
- [x] 1.6 Mark executable (`chmod +x`).

## 2. Justfile integration
- [x] 2.1 Add `just smoke` — runs `scripts/smoke-test.sh http://localhost:9000` with the seeded test credentials.
- [x] 2.2 Add `just smoke-url URL` — runs the script against an arbitrary URL (will be reused for the VPS prod deployment in phase 5).

## 3. Documentation
- [x] 3.1 Add a "Running smoke tests" section to `LOCAL_DEV.md` with the `just smoke` / `just smoke-url` usage and the env vars for overriding credentials.

## 4. Verification
- [x] 4.1 Spin up the local stack (`just up`), seed it, and run `just smoke` — all three checks pass against k3d+Mealie v3.8.0.
- [x] 4.2 Run the script against a deliberately-wrong URL (e.g. `http://localhost:65535`) — fails cleanly with `got 000`, exit 1.
- [x] 4.3 Run with wrong credentials — fails at the auth check with HTTP 401, exit 1.

## 5. Seed-script ergonomics (folded in while here)
- [x] 5.1 Add `DEFAULT_GROUP` / `DEFAULT_HOUSEHOLD` env-var pass-through to `helm/mealie/templates/configmap.yaml` (conditional — only emit when set).
- [x] 5.2 Set `DEFAULT_GROUP: Jenkinz` / `DEFAULT_HOUSEHOLD: JenkinsJnrs` in `helm/values/dev.yaml` so the admin lands in the user's actual household on first boot.
- [x] 5.3 Append a "welcome recipe" creation to `scripts/seed.sh`. Idempotent via slug lookup (Mealie silently auto-renames duplicates instead of 409-ing).
- [x] 5.4 Pre-seed the four other extended-family households (`JenkinsSnrs`, `Munchkins`, `Frenkins`, `Hongkins`) via `POST /api/admin/households`. Idempotent via name lookup. Overridable with `SEED_EXTRA_HOUSEHOLDS` env var.
- [x] 5.5 Fix seed.sh re-auth path: Mealie blocks email changes on built-in admin, so the rotated-credential fallback uses `changeme@example.com` / `testtest`, not `admin@test.com`.
- [x] 5.6 Corrected `LOCAL_DEV.md` + smoke-test defaults to reflect the real post-seed credentials (`changeme@example.com` / `testtest`). Added a "Multi-Household Setup" section explaining the group→household model.
