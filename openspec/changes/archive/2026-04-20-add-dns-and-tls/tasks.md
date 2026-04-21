# Tasks: DNS + Automated TLS

## 1. DNS migration (user action, documented)
- [x] 1.1 Cloudflare free plan signed up; `jenkinz.net` site added.
- [x] 1.2 Auto-scanned DNS records reviewed; email records preserved.
- [x] 1.3 Porkbun TTLs lowered to 300s; waited for propagation.
- [x] 1.4 Porkbun nameservers changed to `isabel.ns.cloudflare.com` + `yahir.ns.cloudflare.com`.
- [x] 1.5 Propagation verified: `dig NS jenkinz.net @1.1.1.1` returns Cloudflare NS.
- [x] 1.6 Cloudflare SSL/TLS mode set to **Full (strict)**.
- [x] 1.7 `A mealie.jenkinz.net` → VPS IP added, Proxied (orange cloud).

## 2. Cloudflare API token for DNS-01 (user action)
- [x] 2.1 Scoped token created — `Zone:Read` + `Zone:DNS:Edit` on `jenkinz.net`, 1-year TTL.
- [x] 2.2 Token saved to 1Password.

## 3. cert-manager installation
- [x] 3.1 `k8s/cert-manager/cluster-issuer-staging.yaml` created.
- [x] 3.2 `k8s/cert-manager/cluster-issuer-prod.yaml` created.
- [x] 3.3 `k8s/cert-manager/test-certificate.yaml` created.
- [x] 3.4 `just tls-bootstrap` added; tested (~60s, cert-manager + secret + issuers).
- [x] 3.5 `just tls-test` added; tested (staging cert Ready in ~90s, self-cleaned).

## 4. Documentation
- [x] 4.1 `k8s/cert-manager/README.md` — full runbook (DNS migration + Cloudflare token + bootstrap + test + troubleshooting).
- [ ] 4.2 Update `infra/README.md` — follow-up note for phase-4 step (optional polish, defer).
- [ ] 4.3 Update root `README.md` — mark phase 4 done in the roadmap table (optional polish, defer).

## 5. Verification
- [x] 5.1 `dig NS jenkinz.net @1.1.1.1` returns Cloudflare NS records.
- [x] 5.2 `dig A mealie.jenkinz.net @1.1.1.1` returns a Cloudflare edge IP (proxied).
- [x] 5.3 `just tls-bootstrap` completes; cert-manager pods all Running.
- [x] 5.4 Both ClusterIssuers `Ready: True` (`letsencrypt-prod` @ 47s, `letsencrypt-staging` @ 49s).
- [x] 5.5 `just tls-test` — Certificate Ready in 90s, then self-cleaned.
- [ ] 5.6 Idempotency drill (optional — re-run `just tls-bootstrap` and confirm no-op).

## 6. Open decisions (resolved)
- [x] 6.1 Cloudflare proxy mode: **orange cloud** (Proxied) with **Full (strict)** TLS — hides origin IP, gets WAF/analytics for free. LE cert serves as origin cert.
- [x] 6.2 Cert-manager install: Helm (`jetstack/cert-manager`), `installCRDs=true`, namespace `cert-manager`.
- [x] 6.3 ClusterIssuer naming: `letsencrypt-staging` + `letsencrypt-prod` (cert-manager convention).
- [x] 6.4 DNS-01 solver: Cloudflare API token (scoped), not the deprecated Global API Key.
- [x] 6.5 Phase 4 does NOT issue a cert for `mealie.jenkinz.net` — deferred to phase 5 with the Mealie Ingress spec.
