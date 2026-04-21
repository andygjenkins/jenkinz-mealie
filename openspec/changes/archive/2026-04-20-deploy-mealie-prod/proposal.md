# Change: Deploy Mealie to Production (Phase 5)

## Why

Phases 3 and 4 built the scaffolding — VPS, K3s, Tailscale, DNS, cert-manager. Phase
5 is the one that makes `https://mealie.jenkinz.net` actually serve the Mealie UI.
After this, the family can start using the recipe manager; every subsequent phase
(backups, SMTP, observability) hardens or extends a live service.

## What Changes

- **`helm/values/prod.yaml`**: rename from `ref.yaml` and rewrite for real prod:
  - `baseUrl: https://mealie.jenkinz.net`
  - `allowSignup: false`
  - Ingress: `enabled: true`, className `traefik`, host `mealie.jenkinz.net`,
    TLS block referencing `mealie-tls` secret, cert-manager annotation
    `cert-manager.io/cluster-issuer: letsencrypt-prod`
  - Persistence: 5 Gi (K3s local-path-provisioner)
  - `seed.enabled: false` (admin bootstrap is manual via Mealie UI on first visit)
  - `defaultGroup: Jenkinz`, `defaultHousehold: JenkinsJnrs` (same as dev; matches
    approved extended-family model)
  - Resource requests/limits sized for the family workload

- **Chart**: add `mealie.secretKey` passthrough so Mealie's JWT signing key can be
  set explicitly (prevents all sessions dying on pod restart). Dev leaves it empty
  (Mealie auto-generates), prod sets it from 1Password.

- **Justfile**: add `just deploy-prod` — runs `helm upgrade --install` against the
  prod kubeconfig with secrets injected via `--set` from env vars
  (`MEALIE_SECRET_KEY`, `POSTGRES_PASSWORD`). Fails fast if either is missing.
  Auto-exports `KUBECONFIG=~/.kube/mealie-prod.yaml` so the right cluster is
  targeted. Idempotent.

- **Smoke-test path**: reuse `just smoke-url https://mealie.jenkinz.net` (already
  exists). Proves: valid TLS, API healthy, auth works, DB accessible — end-to-end
  through Cloudflare → Traefik → Mealie.

- **Documentation**: new section in root `README.md` covering prod deploy flow;
  `helm/values/prod.yaml` header comment explaining the secret-injection pattern.

## Out of Scope (deferred)

- **GitHub Actions deploy automation** — moved to a future `automate-prod-deploy`
  change. Local `just deploy-prod` is sufficient for launch; automation is a
  learning milestone once the flow is proven manually.
- **SMTP wiring** — phase 7.
- **Backups** — phase 6.
- **Grafana Cloud observability** — phase 8.
- **Sealed-secrets migration** — defer indefinitely; `kubectl create secret` from
  1Password is the chosen launch pattern.
- **Admin bootstrap automation in prod** — manual via Mealie UI on first visit is
  simpler and safer than auto-seeding with a real password. Households are still
  auto-created via `DEFAULT_GROUP` / `DEFAULT_HOUSEHOLD` on first boot; the seed
  script is intentionally **not** used in prod.

## Impact

- New capability spec: `prod-deployment`.
- New / renamed files:
  - `helm/values/prod.yaml` (renamed from `ref.yaml` and rewritten)
  - `helm/mealie/values.yaml` — add `mealie.secretKey: ""` default
  - `helm/mealie/templates/secret.yaml` — conditionally include `SECRET_KEY` when set
  - `justfile` — new `deploy-prod` recipe
  - `README.md` — production deploy section updated
- Touches: no existing OpenSpec specs (all new).
- New cluster resources: `mealie` namespace (created by helm), Mealie deployment,
  PVC (5 Gi), Ingress + TLS Certificate (issued by cert-manager).
- Cost impact: €0 additional. Using existing Hetzner node capacity.
