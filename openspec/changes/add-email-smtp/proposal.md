# Change: Email via SMTP (Phase 7)

## Why

Mealie is live at `mealie.jenkinz.net` and about to onboard ~5 families / 10-12
users, with room to grow. Without SMTP configured, Mealie cannot send password
reset emails, cannot send household invitation emails, and has no way to notify
users of account-level events. Every forgotten password routes through Andy
manually, and every new user has to be added by hand instead of accepting an
invitation link. That operational load is already untenable at 12 users and gets
worse with each family added.

Phase 7 wires Mealie to a transactional email provider so password resets and
household invitations become self-service.

## What Changes

### Chart

- Add an `email:` section to `helm/mealie/values.yaml`:
  ```yaml
  email:
    enabled: false
    host: ""                    # e.g. "smtp.resend.com"
    port: 587
    fromName: "Mealie"
    fromEmail: ""               # e.g. "no-reply@mealie.jenkinz.net"
    authStrategy: "TLS"         # TLS | SSL | NONE
    existingSecret: "mealie-smtp"  # provides SMTP_USER + SMTP_PASSWORD
  ```
- Extend `helm/mealie/templates/configmap.yaml` to emit `SMTP_HOST`,
  `SMTP_PORT`, `SMTP_FROM_NAME`, `SMTP_FROM_EMAIL`, `SMTP_AUTH_STRATEGY` when
  `email.enabled: true`.
- Extend `helm/mealie/templates/secret.yaml` (or add a lookup on an external
  Secret) so the Deployment `envFrom`s the `mealie-smtp` Secret and Mealie
  reads `SMTP_USER` and `SMTP_PASSWORD` from it.
- Prod opts in: `helm/values/prod.yaml` sets `email.enabled: true`,
  `email.host: smtp.resend.com`, `email.port: 587`,
  `email.fromEmail: no-reply@mealie.jenkinz.net`,
  `email.authStrategy: TLS`.

### Secrets

A single `mealie-smtp` Secret in the `mealie` namespace holds two keys:

| Key | Source |
|---|---|
| `SMTP_USER` | Resend username (literal string `resend`) |
| `SMTP_PASSWORD` | Resend API key (acts as SMTP password), saved to 1Password |

### Justfile

- `just smtp-bootstrap` — creates/updates the `mealie-smtp` Secret from env
  vars `SMTP_USER`, `SMTP_PASSWORD` (fails fast if missing; idempotent; same
  shape as `just backup-bootstrap`).

### Documentation

- `k8s/smtp/README.md`: provider choice rationale (Resend vs SES vs Gmail
  app password), Resend signup + domain verification flow, the exact DNS
  records to add at Cloudflare for `mealie.jenkinz.net` (SPF TXT, DKIM
  CNAMEs, optional DMARC), bootstrap flow, how to test delivery, and how
  to swap providers later (change chart values, re-bootstrap the Secret).
- Root `README.md` — add the `just smtp-bootstrap` one-time step to the
  Production Deploy section.

### Provider decision (design.md)

Resend is the recommended default (free tier 3k/mo, clean DKIM/SPF via
Cloudflare DNS, professional from-address). design.md compares Resend,
Amazon SES, and Gmail SMTP app-password with a pros/cons table so the
choice is reversible by re-running `just smtp-bootstrap` against a
different provider without chart changes.

## Capabilities

### New Capabilities

- `email-notifications`: Configurable outbound SMTP for Mealie —
  per-environment enable flag, non-secret SMTP settings in the chart,
  credentials via an external Secret, and a bootstrap recipe that
  creates that Secret from env vars. Plus the runbook (provider setup
  + DNS records) needed to actually make mail deliverable.

### Modified Capabilities

None. The existing `prod-deployment` spec describes how we deploy; adding
SMTP is a new capability layered on top, not a change to the deploy
contract. The `just deploy-prod` recipe is unchanged (no new `--set`
flags — the Secret is referenced by name).

## Impact

- New capability spec: `email-notifications`.
- New files:
  - `k8s/smtp/README.md`
- Touches:
  - `helm/mealie/values.yaml` (new `email:` section with safe disabled defaults)
  - `helm/mealie/templates/configmap.yaml` (emit SMTP_* when enabled)
  - `helm/mealie/templates/secret.yaml` or Deployment (`envFrom` the
    `mealie-smtp` Secret when enabled)
  - `helm/values/prod.yaml` (enable SMTP, point at Resend, set from-address)
  - `justfile` (one new recipe: `smtp-bootstrap`)
  - `README.md` (one-time bootstrap step)
- New third-party dependency: Resend account + verified sender domain.
- Cost impact: Resend free tier (3,000 emails/month) vs. realistic volume
  (<50/month: password resets + invitations for 12-15 users). **$0/month.**
- DNS changes at Cloudflare (SPF TXT, DKIM CNAMEs) — out-of-band, documented
  in the runbook, not automated.

## Out of Scope (deferred)

- **Custom email templates.** Mealie's bundled templates are fine for a
  family install.
- **Bounce / complaint handling.** Irrelevant at <50 messages/month; Resend's
  dashboard surfaces bounces if we ever need to investigate.
- **Second-channel notifications** (Apprise, Discord, Slack webhooks).
  Mealie supports them, but email covers password reset and invitations,
  which is the actual unblocker.
- **OIDC / SSO.** Separate future change; not blocked by or blocking this one.
- **Grafana Cloud agent.** Phase 8, the next change after this one.
