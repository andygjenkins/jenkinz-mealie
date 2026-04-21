# Local Development Guide

## Prerequisites

- **Docker** — Docker Desktop or [OrbStack](https://orbstack.dev/)
- **[k3d](https://k3d.io/)** — `brew install k3d`
- **[Tilt](https://tilt.dev/)** — `brew install tilt-dev/tap/tilt`
- **[Helm](https://helm.sh/docs/intro/install/)** 3.x+ — `brew install helm`
- **[just](https://github.com/casey/just)** — `brew install just`
- **kubectl** — `brew install kubectl`

## Quick Start

```bash
just up     # creates k3d cluster "mealie-dev" (first run) and launches Tilt
just seed   # creates admin@test.com / testtest + a welcome recipe
just smoke  # verify the deployment with the API smoke test
just open   # open http://localhost:9000 in the browser
```

Tilt's dashboard is at http://localhost:10350 — use it to watch logs, restart
resources, and see the live Helm render.

## Lifecycle Recipes

| Recipe | What it does |
|---|---|
| `just up` | Create or reuse the `mealie-dev` k3d cluster, then `tilt up`. |
| `just down` | `tilt down` — stop Tilt and its port-forwards, leave the cluster running. |
| `just stop` | `k3d cluster stop mealie-dev` — preserve the cluster for a quick restart. |
| `just clean` | Full teardown: Tilt down, delete namespace, delete k3d cluster. |

## Default Credentials

Mealie ships with a baked-in admin account on first boot:

- **Before `just seed`:** `changeme@example.com` / `MyPassword`
- **After `just seed`:** `changeme@example.com` / `testtest` — the script rotates the password and updates the profile. Mealie's security blocks email changes for the built-in admin, so the email stays as the default.
- **Group / household (dev):** `Jenkinz` / `JenkinsJnrs`, set via `DEFAULT_GROUP` / `DEFAULT_HOUSEHOLD` in `helm/values/dev.yaml`
- **Pre-seeded households:** `JenkinsJnrs` (admin's), plus `JenkinsSnrs`, `Munchkins`, `Frenkins`, `Hongkins` — created by `scripts/seed.sh` via the admin API. Override the list with `SEED_EXTRA_HOUSEHOLDS="Foo Bar Baz" just seed`.

**PostgreSQL:**
- Host: `mealie-postgres` (in-cluster) or `localhost:5432` (port-forwarded by Tilt)
- User: `mealie`
- Password: `mealie-dev-password`
- Database: `mealie`

## Multi-Household Setup (Extended Family)

Mealie has a **two-level tenancy model**: one group with many households.

- **Group** (top level, e.g. `Jenkinz`) owns the shared recipe library: recipes, tags,
  categories, tools, foods, units. Every user in the group sees the same recipes.
- **Households** (sub-level, e.g. `Main`, `Parents`, `Sister`, `Grandma`) each have
  their **own** meal plans, shopping lists, and integrations. Users are assigned to
  exactly one household.

The dev cluster pre-seeds five Jenkinz households (see the **Pre-seeded households**
entry above). To add more, either:

- **Extend the seed list:** `SEED_EXTRA_HOUSEHOLDS="New1 New2" just seed` (idempotent —
  existing households are skipped).
- **Or do it manually:** log in as the admin and go to **Admin → Manage Households →
  Create**. Then **Admin → Manage Users** to invite family members and assign each to
  a household (invite links go by email if SMTP is configured, otherwise by token).

**Known Mealie limitation:** there's currently no cross-household meal plan or shopping
list sharing. Recipes are fully shared at the group level, but planning is per-household.

## Running Smoke Tests

After `just up` + `just seed`, verify the deployment is healthy:

```bash
just smoke                                  # against local Tilt stack (http://localhost:9000)
just smoke-url https://mealie.jenkinz.net   # against any URL (prod, staging, etc.)
```

The smoke test runs three checks:

1. **API health** — `GET /api/app/about` returns 200 with a version string.
2. **Authentication** — `POST /api/auth/token` returns an access token.
3. **DB-backed read** — authenticated `GET /api/users/self` returns the caller's email.

Any failure exits non-zero with the failing check and the response body.
Override credentials with `SMOKE_EMAIL=… SMOKE_PASSWORD=… just smoke`.

## Useful Commands

```bash
# Check pod status
just pods                 # or: kubectl get pods -n mealie

# Follow logs
just logs                 # Mealie
just logs-db              # PostgreSQL

# PostgreSQL shell
just psql

# Switch kube-context manually
kubectl config use-context k3d-mealie-dev
```

## Troubleshooting

**Mealie not starting:**
- Check pods: `just pods`
- Check Mealie logs: `just logs`
- Check Postgres logs: `just logs-db`

**`just up` hangs or fails:**
- Confirm Docker is running: `docker version`
- If the k3d cluster is in a bad state, nuke and rebuild: `just clean && just up`

**Port 9000 already in use:**
- `lsof -i :9000` to find the process; kill it or reuse the existing Mealie.

**Switching away from Tilt temporarily:**
- `just down` stops Tilt; the cluster keeps running. `just up` resumes.
