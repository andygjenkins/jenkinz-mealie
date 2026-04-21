# Tasks: Deploy Mealie to Production

## 1. Chart updates
- [x] 1.1 Added `mealie.secretKey: ""` default to `helm/mealie/values.yaml` with explanatory comment.
- [x] 1.2 Updated `helm/mealie/templates/secret.yaml` — conditionally adds `SECRET_KEY` when set.
- [x] 1.3 Dev rendering verified unchanged (no `SECRET_KEY` emitted when value is empty).

## 2. prod.yaml
- [x] 2.1 `ref.yaml` renamed to `prod.yaml`.
- [x] 2.2 Rewritten for real prod — baseUrl, signup off, household defaults, persistence, ingress with cert-manager annotations + TLS block, seed off, secrets intentionally empty.

## 3. Justfile recipe
- [x] 3.1 `just deploy-prod` — fails fast without env vars, targets prod kubeconfig, creates namespace idempotently, `helm upgrade --install` with `--set` for both secrets, waits 5m.

## 4. Secrets (manual, one-time)
- [x] 4.1 `MEALIE_SECRET_KEY` generated via `openssl rand -hex 32` and stored in 1Password.
- [x] 4.2 `POSTGRES_PASSWORD` generated via `openssl rand -base64 24` and stored in 1Password.
- [x] 4.3 Export-and-deploy flow documented in `README.md`.

## 5. Deploy + Verify
- [x] 5.1 `just deploy-prod` completed.
- [x] 5.2 Pods reached Ready (Mealie + Postgres).
- [x] 5.3 cert-manager issued `mealie-tls` via DNS-01.
- [x] 5.4 HTTPS reachable at `https://mealie.jenkinz.net`.
- [x] 5.5 Smoke test against prod URL passed (after admin rotation — see 5.6).
- [x] 5.6 **Admin bootstrap via Mealie's first-run wizard** (not the profile-edit path): email + password both customizable. Admin is now the user's real email + rotated password, saved to 1Password.
- [x] 5.7 `JenkinsJnrs` household exists from `DEFAULT_HOUSEHOLD`. Additional households can be created via Admin → Manage Households UI, or by running `scripts/seed.sh https://mealie.jenkinz.net/api` with overridden credentials post-launch.

## 6. Documentation
- [x] 6.1 `README.md` has a Production Deploy section covering env-var + `just deploy-prod` flow.
- [x] 6.2 `helm/values/prod.yaml` header comment explains the secret-injection pattern.

## 7. Open decisions (resolved)
- [x] 7.1 Secret handling: inject at `helm --set` time (not refactoring the chart to external-secret refs). Simpler; consistent with "no sealed-secrets yet". Future sealed-secrets change can refactor.
- [x] 7.2 Admin bootstrap: manual via Mealie UI. Seed disabled in prod. Post-launch, can run `SEED_ADMIN_PASSWORD=<real> scripts/seed.sh https://mealie.jenkinz.net/api` to pre-seed the 4 other households if desired — but the default is "admin creates via UI".
- [x] 7.3 Deploy surface: local `just deploy-prod` only. GH Actions automation deferred to `automate-prod-deploy`.
- [x] 7.4 TLS cert name: `mealie-tls` (in the `mealie` namespace). Standard Ingress + cert-manager convention.
