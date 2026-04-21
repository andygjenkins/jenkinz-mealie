# Change: DNS + Automated TLS (Phase 4)

## Why

The VPS has a K3s cluster but no public presence. Phase 4 wires the real-world
plumbing that turns `https://mealie.jenkinz.net` into a working URL:

- **DNS migration**: `jenkinz.net` is registered at Porkbun but DNS is on Porkbun's
  own nameservers; we move authoritative DNS to **Cloudflare** (keeping Porkbun as
  registrar) so we can use Cloudflare as a reverse proxy / WAF / analytics front-
  end, and so cert-manager can use Cloudflare's API for DNS-01 ACME challenges.
- **Automated TLS**: install **cert-manager** into the cluster, wire up Let's
  Encrypt issuers (staging + prod) using Cloudflare's DNS-01 solver. Future phases
  just reference the ClusterIssuer in their Ingress and get a cert automatically.
- **Observability hook**: Cloudflare's orange-cloud proxy gives us free per-request
  analytics, bot scoring, and WAF — the answer to "show me who's poking at my site"
  before we have Grafana Cloud (phase 8) running.

## What Changes

- **DNS (manual, documented in `k8s/cert-manager/README.md`)**:
  - Move `jenkinz.net` nameservers from Porkbun to Cloudflare (free plan).
  - Add `A` record `mealie.jenkinz.net` → VPS public IPv4 with **proxy status:
    Proxied (orange cloud)**.
  - Cloudflare TLS mode set to **Full (strict)** so Cloudflare talks HTTPS to
    Traefik using the Let's Encrypt cert as the origin cert.

- **cert-manager**:
  - Install into the `cert-manager` namespace via the official Helm chart, CRDs
    bundled (`installCRDs=true`).
  - Pinned to a known-good minor (~v1.19.x in 2026; use whichever is current at
    install time, documented).

- **Cloudflare secret** (for DNS-01):
  - Create a scoped Cloudflare API token with exactly `Zone:Read` (all) +
    `Zone:DNS:Edit` (for `jenkinz.net`).
  - Stored in 1Password; `kubectl create secret` at bootstrap time (consistent with
    our no-sealed-secrets-yet stance).

- **ClusterIssuers** (committed to git under `k8s/cert-manager/`):
  - `letsencrypt-staging` — for first-time validation without hitting LE rate limits.
  - `letsencrypt-prod` — for real certs.
  - Both use the Cloudflare DNS-01 solver pointing at the above secret.

- **Justfile recipe**: `just tls-bootstrap` — adds the Jetstack Helm repo, installs
  cert-manager, creates the Cloudflare secret from `CF_API_TOKEN` env var, applies
  the two ClusterIssuers. Idempotent.

- **Justfile recipe**: `just tls-test` — applies a staging Certificate for
  `test.jenkinz.net`, waits for Ready, deletes it. Proves DNS-01 works end-to-end
  without burning a prod rate-limit slot or committing to a real subdomain.

- **Documentation**: `k8s/cert-manager/README.md` — complete runbook (DNS
  migration, Cloudflare API token generation, bootstrap, test, troubleshooting).

## Out of Scope (deferred)

- **Issuing a cert for `mealie.jenkinz.net`** — happens in phase 5 (`deploy-mealie-
  prod`) as part of the Ingress spec. Phase 4 only proves the machinery works.
- **Wildcard cert for `*.jenkinz.net`** — defer to when we have a second subdomain
  (e.g. `grafana.jenkinz.net` in phase 8 or beyond).
- **HTTP-01 fallback** — not needed; DNS-01 is wildcard-capable and works through
  Cloudflare proxy.
- **mTLS / client certs** — overkill for a family Mealie.
- **Cloudflare page rules / cache rules / firewall rules beyond defaults** — add
  reactively if a real need shows up.

## Impact

- New capability spec: `tls-issuance`.
- New files:
  - `k8s/cert-manager/cluster-issuer-staging.yaml`
  - `k8s/cert-manager/cluster-issuer-prod.yaml`
  - `k8s/cert-manager/test-certificate.yaml` (used by `just tls-test`)
  - `k8s/cert-manager/README.md`
  - `justfile` recipes (`tls-bootstrap`, `tls-test`)
- Touches: `openspec/project.md` (already updated for Porkbun/Cloudflare split).
- New cluster components: cert-manager (in `cert-manager` namespace), one Secret,
  two ClusterIssuers.
- New cloud dependencies: Cloudflare account (free plan), scoped API token.
- Cost impact: €0 (Cloudflare free tier; Let's Encrypt free).
