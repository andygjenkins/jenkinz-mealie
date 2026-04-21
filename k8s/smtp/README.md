# SMTP Email (Phase 7)

Outbound email for Mealie — password resets and household invitation links.
Uses Resend as the transactional-mail provider, sending from
`no-reply@mealie.jenkinz.net`.

> **Not for inbound mail.** Mealie only sends; it does not receive. Inbound
> for `mealie.jenkinz.net` is not configured and is out of scope.

## Why Resend (vs. SES, Gmail SMTP)

| Criterion | **Resend** | Amazon SES | Gmail SMTP app-password |
|---|---|---|---|
| Cost at <50 msg/mo | $0 (free: 3,000/mo) | ~$0.005 | $0 |
| From-address on our domain | ✅ `no-reply@mealie.jenkinz.net` | ✅ | ❌ stuck on `andygjenkins@gmail.com` |
| Setup friction | Low (3 DNS records, 1 API key) | Medium (AWS, sandbox ticket) | Very low (app password in Google) |
| DKIM / SPF through our DNS | ✅ clean CNAMEs + SPF include | ✅ same shape | N/A (Google's domain) |
| Lock-in to personal account | None | None | **High — bus-factor on Andy's Google account** |

Resend wins on professional sender address and low lock-in. See
`openspec/changes/archive/*add-email-smtp*/design.md` for the full rationale.

The chart's `email.*` values are provider-agnostic — if Resend's pricing or
business changes, swap to SES or another provider by editing
`helm/values/prod.yaml` and re-running `just smtp-bootstrap` with different
credentials. No chart changes needed.

## One-time setup

### 1. Resend account + sender domain

1. Sign up at https://resend.com (free tier; no card). Save the login to
   1Password as **Resend – account (mealie)**.
2. Dashboard → **Domains → Add Domain** → enter `mealie.jenkinz.net`.
3. Resend displays DNS records to add. Typically three:
   - One **TXT** record (SPF): usually at `send.mealie.jenkinz.net`, value
     `v=spf1 include:amazonses.com ~all` (Resend uses SES under the hood).
   - Two **CNAME** records (DKIM): at
     `resend._domainkey.mealie.jenkinz.net` and a second
     `resend2._domainkey.mealie.jenkinz.net`, pointing at
     `<something>.dkim.amazonses.com`.

   Exact names and targets are generated per-domain — copy them from the
   Resend dashboard. Leave the Resend tab open while you edit Cloudflare.

### 2. DNS at Cloudflare

The `jenkinz.net` zone lives at Cloudflare. Open the zone → **DNS → Records**.

For each record Resend showed you:

- Add it on the **subdomain** (`send.mealie.jenkinz.net`,
  `resend._domainkey.mealie.jenkinz.net`, etc.) — not the apex.
- **Set Proxy status to DNS only (grey cloud, not orange).** Cloudflare's HTTP
  proxy mangles mail-authentication records; DKIM/SPF only work if traffic is
  unproxied. The UI shows a toggle per record — click it to grey.
- Leave TTL at **Auto**.

Back in the Resend dashboard, click **Verify**. DNS usually propagates within
a few minutes; if it's still pending after 15 minutes, re-check that each
record exactly matches what Resend specified and is grey-cloud.

**Optional: DMARC.** If you want to add a DMARC policy later, add a TXT record
at `_dmarc.mealie.jenkinz.net` with value
`v=DMARC1; p=none; rua=mailto:andygjenkins@gmail.com`. Not required for
delivery — Gmail/iCloud accept SPF+DKIM-aligned mail without DMARC — but it
gives you bounce/fraud reports if deliverability ever gets weird.

### 3. Resend API key

In the Resend dashboard → **API Keys → Create**:

- Name: `mealie-prod-smtp`
- Permission: **Sending access** (not full access)
- Domain: restrict to `mealie.jenkinz.net`

Copy the key once (Resend will not show it again). Save to 1Password as
**Resend – API key (mealie-prod)**.

### 4. Bootstrap the Kubernetes Secret

```bash
export SMTP_USER=resend
export SMTP_PASSWORD="$(op read 'op://Personal/Resend – API key (mealie-prod)/credential')"

just smtp-bootstrap
```

The recipe creates the `mealie-smtp` Secret in the `mealie` namespace with two
keys: `SMTP_USER` and `SMTP_PASSWORD`. It's idempotent — re-run it anytime to
rotate the key without deleting the Secret.

### 5. Deploy and verify

```bash
just deploy-prod
```

The rollout picks up the new ConfigMap keys (`SMTP_HOST`, `SMTP_PORT`,
`SMTP_FROM_NAME`, `SMTP_FROM_EMAIL`, `SMTP_AUTH_STRATEGY`) and the
`envFrom` on `mealie-smtp` for the two credential keys.

Smoke-test with a real password reset:

1. In the Mealie UI (https://mealie.jenkinz.net), click **Forgot password**
   and enter a test-user's email (Gmail and iCloud both work — try each).
2. Within ~60s, an email arrives from
   `Mealie <no-reply@mealie.jenkinz.net>`.
3. Open the full headers and confirm:
   - `Authentication-Results: ... spf=pass ... dkim=pass`
   - `From` aligned to `mealie.jenkinz.net`
4. Click the reset link, set a new password, log in. End-to-end success.

If the email lands in spam or fails SPF/DKIM, **don't** just re-send — fix
DNS. Common causes:

- DKIM CNAMEs are orange-clouded at Cloudflare (toggle off).
- SPF TXT record is on the wrong subdomain (must be exactly what Resend
  specified — not on the apex, not on `mealie.jenkinz.net` directly unless
  Resend told you so).
- Domain still shows "Pending" in Resend — wait for Verified.

## Rotation (annual or on leak)

1. Create a new API key at Resend with the same scope.
2. Update 1Password (**Resend – API key (mealie-prod)**) with the new value.
3. Re-run `just smtp-bootstrap` with the new `SMTP_PASSWORD`.
4. Restart the Mealie pod so it re-reads the Secret:
   `kubectl -n mealie rollout restart deployment/mealie`.
5. Delete the old key at Resend.

## Swapping providers

The chart is provider-agnostic. To move off Resend (to SES, Mailgun, Gmail
app-password, a self-hosted Postfix, whatever):

1. Edit `helm/values/prod.yaml` → update `email.host`, `email.port`,
   `email.fromEmail`, `email.authStrategy` as needed for the new provider.
2. Update the DNS records at Cloudflare for the new provider's DKIM/SPF.
3. Put the new SMTP username + password in 1Password.
4. Export `SMTP_USER` and `SMTP_PASSWORD` with the new values.
5. `just smtp-bootstrap` (re-bootstraps the Secret).
6. `just deploy-prod` (rolls out the new configmap).

No chart code changes required.

## Troubleshooting

**Password-reset emails never arrive, but the app doesn't error.**
Tail the Mealie logs during a reset attempt:
`kubectl -n mealie logs -l app.kubernetes.io/name=mealie --tail=100 -f`.
SMTP errors (auth failure, TLS handshake, wrong host) show up as tracebacks
from the send call. If the log is silent, the app isn't being asked to send
— check that the user's email is configured on the user record.

**Emails arrive but land in spam.**
Open the full headers in the receiving inbox. Look at
`Authentication-Results`. If SPF=fail, the TXT record is wrong or on the
wrong subdomain. If DKIM=fail, the CNAMEs are wrong or orange-clouded.

**"Verified" toggled back to "Pending" in Resend.**
DNS drift — usually a Cloudflare record got proxied (orange cloud) after
an edit. Re-toggle to grey cloud.

**Rate limits.**
Resend free tier is 3,000/month and 100/day. Family Mealie volume is
<10/day. If you hit the limit, something's wrong (loop, misconfigured
workflow) — investigate before upgrading the plan.
