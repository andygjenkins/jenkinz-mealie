# Design: Email via SMTP

## Context

Mealie v3.16 supports outbound email over SMTP (no mail-API integrations).
The backend reads a small set of env vars — `SMTP_HOST`, `SMTP_PORT`,
`SMTP_FROM_NAME`, `SMTP_FROM_EMAIL`, `SMTP_AUTH_STRATEGY`, `SMTP_USER`,
`SMTP_PASSWORD` — and uses them for password-reset links and household
invitation emails. Mail is opt-in: if those vars aren't set, the app runs
fine but the "forgot password" and "invite by email" UI flows fail.

Current state: prod has `ALLOW_SIGNUP=false`, one admin account, no SMTP.
Every user onboarding and every password reset is a manual admin task.
Dev has no reason to send mail; we want dev unchanged.

Domain / DNS constraints (relevant because transactional email deliverability
depends on DNS records being present on the sending domain):

- Domain `jenkinz.net` is registered at **Porkbun**, DNS is hosted at **Cloudflare** (nameservers delegated there).
- Any SPF/DKIM/DMARC records go in the Cloudflare dashboard, not in the repo.
- From-address lives on a subdomain: `no-reply@mealie.jenkinz.net`. Sending from a subdomain means the primary `jenkinz.net` SPF policy is unaffected.

Secret management pattern in this repo: manual `kubectl` Secret creation,
seeded from 1Password via `just <thing>-bootstrap` recipes. No sealed-secrets,
SOPS, or External Secrets. This change follows that pattern (see
`just backup-bootstrap` in the `add-prod-backups` change as the reference).

## Goals / Non-Goals

**Goals:**

- Password resets work end-to-end without admin intervention.
- Household invitation emails work (Mealie generates a link, sends the mail).
- SMTP is **opt-in per environment**: prod enables it, dev stays off.
- Credentials never enter the repo or `helm/values/*.yaml`; only a Secret name does.
- The `just deploy-prod` interface is unchanged — no new required env vars at deploy time (the Secret is referenced by name).
- Provider choice is reversible: swapping Resend → SES → Gmail requires only re-running `just smtp-bootstrap` with different values and flipping a few chart values. No chart structural changes.
- A runbook exists so a future Andy (or a helper) can reproduce the setup, including the DNS records needed at Cloudflare.

**Non-Goals:**

- Bounce/complaint handling, suppression lists, mail analytics.
- Custom email templates (Mealie's bundled templates are fine).
- Inbound email (receiving, parsing, reply-to flows).
- Warm-up strategy — irrelevant at <50 messages/month on a fresh subdomain that's protected by the provider's shared reputation.
- Secret rotation automation. Rotation is a documented manual step (regenerate Resend API key, re-run `smtp-bootstrap`, `kubectl rollout restart`).

## Decisions

### Decision 1: Provider — Resend (recommended), with SES and Gmail app-password as alternatives

**Chosen: Resend.**

Comparison for our actual shape (≤50 messages/month, family self-hosting, DNS at Cloudflare, jenkinz.net subdomain):

| Criterion | **Resend** | Amazon SES | Gmail SMTP (app password) |
|---|---|---|---|
| Monthly cost at our volume | $0 (free: 3,000/mo) | ~$0.005 (SES: $0.10/1k) | $0 |
| Setup friction | Low: signup, verify domain via 3 DNS records, generate API key | Medium: AWS account, verify domain, move out of sandbox (support ticket), IAM user for SMTP creds | Very low: generate app password in Google account |
| From-address | `no-reply@mealie.jenkinz.net` (subdomain we control) | `no-reply@mealie.jenkinz.net` | **`andygjenkins@gmail.com`** (fixed; can't spoof the subdomain without DKIM-via-Workspace gymnastics) |
| DKIM / SPF | Provider-managed DKIM CNAMEs + SPF include, straightforward at Cloudflare | Provider-managed DKIM CNAMEs + SPF include | Relies on Google's existing SPF/DKIM for the sender's Gmail address |
| Deliverability to Gmail/iCloud recipients | Good — dedicated pool, proper DKIM alignment | Good (once out of sandbox) | Good |
| Reversibility if we outgrow it | Medium (re-run bootstrap, swap DNS) | Same | Same |
| Operational complexity | Dashboard, API keys, done | AWS console, IAM, SES sandbox gates | Two-factor + app passwords in one person's Google account |
| Lock-in / bus-factor risk | Low — SMTP is standard; no Resend-specific API in Mealie | Low | **High** — tied to Andy's personal Google account |

**Rationale for Resend:**

- The from-address is the clearest differentiator. `no-reply@mealie.jenkinz.net` is the professional, scalable choice — family members see a branded sender, not a personal Gmail. Gmail SMTP would force `andygjenkins@gmail.com` to appear as the sender, which looks wrong for a shared-family service and creates a bus-factor risk (if Andy ever changes or loses the Gmail account, email stops working).
- Resend's DNS flow is the cleanest of the three for a Cloudflare-hosted domain: the dashboard generates exact records; paste them into Cloudflare; verification in minutes.
- Free tier covers 60× our projected volume, so there is zero cost runway.
- SES would be the right choice if we were sending 100k+ messages/month. At our volume the extra ceremony (sandbox removal, IAM) isn't justified by the $0.005/month saving.

**Rationale for documenting alternatives rather than hard-coding Resend:**

- The chart layout (host / port / fromEmail / authStrategy / existingSecret) is provider-agnostic — every SMTP provider fits.
- If Resend's pricing or business changes, we want the swap to be a values-file edit plus a re-bootstrap, not a chart rewrite.

### Decision 2: Non-secret settings in values, credentials in a separate Secret

Mealie takes all seven SMTP env vars from the same pod env. We split them:

- `helm/mealie/templates/configmap.yaml` emits **five** non-secret vars:
  `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM_NAME`, `SMTP_FROM_EMAIL`,
  `SMTP_AUTH_STRATEGY`.
- A separate Kubernetes Secret `mealie-smtp` holds **two** secret vars:
  `SMTP_USER` and `SMTP_PASSWORD`. The Deployment `envFrom`s it when
  `email.enabled: true`.

**Why split:** host/port/from-address are configuration (belong in
`values.yaml`, diffable, reviewable). User/password are credentials (belong
only in a Secret seeded from 1Password, never in the repo, never in
`helm --set` history).

**Alternative considered:** one Secret with all seven keys. Rejected because
it forces all config through the bootstrap recipe, making routine changes
(e.g. bumping `SMTP_PORT`) require re-running the recipe instead of a
chart-values PR.

### Decision 3: Bootstrap via `just smtp-bootstrap`, not `helm --set`

Consistent with `just backup-bootstrap`: the Secret is created/updated
out-of-band by an idempotent recipe that reads env vars, fails fast on
missing ones, and uses `kubectl apply --dry-run=client -o yaml | kubectl apply -f -`
to be re-runnable.

**Why not `helm --set smtp.password=...`:** `--set` values end up in
`helm history` and the release Secret. Keeping credentials out of the
release object means `helm get values` never leaks them.

**Why not a Helm post-install hook that reads from 1Password:** would
require a 1Password CLI or Connect agent in-cluster, which is a whole new
system. Manual bootstrap matches the agreed plan ("no SOPS, sealed-secrets,
External Secrets at launch").

### Decision 4: `just deploy-prod` unchanged — zero new required env vars

The existing recipe only sets `MEALIE_SECRET_KEY` and `POSTGRES_PASSWORD` via
`--set`. After this change, deploys still take only those two. The SMTP
credential flow is fully decoupled: `just smtp-bootstrap` is a one-time
(or on-rotation) manual step that runs independently of deploys. The
Deployment picks up the Secret via `envFrom`, so a rollout after bootstrap
is the only coupling.

### Decision 5: Dev stays off

`helm/mealie/values.yaml` ships with `email.enabled: false`. When disabled,
the configmap omits the SMTP_* keys and the Deployment does not reference
`mealie-smtp`. The chart renders cleanly in dev without anyone needing to
create the Secret, and the k3d dev loop is unaffected.

### Decision 6: From-address on a subdomain (`mealie.jenkinz.net`), not apex

From-address is `no-reply@mealie.jenkinz.net`. This keeps the DKIM/SPF/DMARC
policy for email scoped to the subdomain that Mealie actually sends from.
If we add another app later (Vaultwarden, Immich) and give it its own
subdomain sender (e.g. `vaultwarden.jenkinz.net`), its DKIM records are
isolated from Mealie's. Apex (`no-reply@jenkinz.net`) would conflate all
future senders under one SPF policy and one DKIM key, which is harder to
rotate and debug.

## Risks / Trade-offs

- **[Risk] Resend account or API key compromised** → Mitigation: the API key is scoped to a single sender domain at Resend (not account-wide). If exposed, rotate the key, re-run `just smtp-bootstrap`, `kubectl rollout restart deployment/mealie`. Blast radius is "spam from our domain for the time window before rotation" — the attacker cannot read mail or touch anything else.
- **[Risk] DNS records for DKIM/SPF mis-configured; mail lands in spam for Gmail/iCloud recipients** → Mitigation: Resend dashboard verifies DKIM records before send is allowed; the runbook includes a delivery test against at least one Gmail and one iCloud inbox as part of the acceptance test. If verification fails, fix the DNS records before shipping.
- **[Risk] DMARC not set** → Mitigation: add a relaxed DMARC policy (`p=none`) in the runbook as an optional step. Not strictly required — Gmail still accepts SPF+DKIM-aligned mail without DMARC — but documented so it's easy to add later if deliverability issues arise.
- **[Risk] Resend outage / pricing change / shutdown** → Mitigation: no Resend-specific integration code; migration is chart values + `smtp-bootstrap` + DNS swap. Documented in the runbook's "swap providers" section.
- **[Risk] DNS records live outside this repo (at Cloudflare)** → Mitigation: runbook documents the exact records with expected values, so they're reproducible; link the Cloudflare zone from the runbook. Acceptable trade-off vs. pulling in a Terraform/Pulumi Cloudflare provider for three records.
- **[Trade-off] Manual bootstrap vs. automated secret sync** → We re-run bootstrap on credential rotation. At "rotate annually" cadence this is negligible. Revisit only when we have 3+ apps needing Secret rotation.
- **[Trade-off] Resend account tied to Andy's email** → Same bus-factor as other provider accounts (Hetzner, Backblaze, Cloudflare). Documented in 1Password; out of scope to solve in this change.

## Migration Plan

This is a new capability, not a migration. Deployment order:

1. Sign up at Resend, add `mealie.jenkinz.net` as a sender domain, get the DNS records.
2. Add the DNS records at Cloudflare (SPF TXT, DKIM CNAMEs). Wait for Resend to mark the domain "verified".
3. Generate a Resend API key scoped to that domain. Save to 1Password.
4. Land the chart changes + prod values via PR.
5. Run `just smtp-bootstrap` with `SMTP_USER=resend` and `SMTP_PASSWORD=<api-key>`. Verifies the Secret exists.
6. Run `just deploy-prod`. Deployment picks up the new configmap keys and `envFrom`s the Secret.
7. Trigger a password reset for a test user; confirm receipt in inbox; complete the reset flow.

**Rollback strategy:**

- If mail delivery breaks after deploy: flip `email.enabled: false` in `helm/values/prod.yaml` and re-deploy. Mealie goes back to the pre-change behavior (no SMTP; forgot-password UI errors). Credentials remain in the Secret, untouched.
- If the Resend account must be abandoned: re-run `smtp-bootstrap` with a different provider's creds (e.g. SES SMTP creds), update `email.host`/`email.port`/`email.authStrategy` in prod values, update the DNS records at Cloudflare, `kubectl rollout restart deployment/mealie`. No chart changes needed.

## Open Questions

All resolved by this design:

- **Provider?** Resend.
- **From-address?** `no-reply@mealie.jenkinz.net`.
- **Secret vs values split?** Five non-secret in configmap; two secret in Secret.
- **Bootstrap shape?** Mirror `just backup-bootstrap`.
- **Dev behavior?** SMTP disabled by default in dev.
