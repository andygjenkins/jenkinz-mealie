# Change: Add Deployment Smoke Tests

## Why

There's no automated way to verify a Mealie deployment is healthy after `helm upgrade` /
initial install. Phase 1 of the hosting plan needs a trustable "is it actually up" check
that every later phase (VPS provisioning, TLS, backups, etc.) can reuse as an acceptance
gate.

## What Changes

- Add `scripts/smoke-test.sh`: a single bash script that hits the Mealie API and verifies
  health, authentication, and basic database-backed operations.
- Add justfile recipes: `just smoke` (local, via port-forward) and `just smoke-url <url>`
  (any URL — used later for the VPS prod deployment).
- Script is environment-agnostic: takes a base URL, detects TLS automatically via `curl`,
  exits non-zero on any failure with a clear summary.
- Document usage in `LOCAL_DEV.md`.

## Out of Scope (future changes if wanted)

- Playwright UI tests — separate change; the API check is sufficient for deployment-gate
  purposes.
- Pre/post upgrade baseline diffing and rollback detection — premature before we have a
  real prod deployment.
- CI/CD integration — folded into the phase-5 `deploy-mealie-prod` change.

## Impact

- Affected specs: `smoke-tests` (new capability).
- Affected code: `scripts/smoke-test.sh` (new), `justfile` (add recipes),
  `LOCAL_DEV.md` (docs).
- Dependencies: `curl`, `jq` (both already standard dev tooling).
