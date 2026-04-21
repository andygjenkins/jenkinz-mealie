# Tasks: Email via SMTP (Phase 7)

## 1. Resend setup (user action, one-time)

- [ ] 1.1 Sign up at https://resend.com (free tier; no card needed). Authenticate with Andy's email and save credentials to 1Password as "Resend – account (mealie)".
- [ ] 1.2 Add sending domain `mealie.jenkinz.net` in the Resend dashboard → Domains → Add Domain. Resend generates three DNS records: one SPF TXT, two DKIM CNAMEs (sometimes a return-path record as well). Leave the tab open — the exact record names/values are provider-assigned.
- [ ] 1.3 Add those records at Cloudflare for zone `jenkinz.net`. Records live on the `mealie.jenkinz.net` subdomain. **Turn the orange cloud OFF** on the DKIM CNAMEs (Cloudflare's proxy mangles mail-auth records). SPF TXT and any other TXT records are DNS-only by default.
- [ ] 1.4 Back in Resend, wait for the domain to move to "Verified" (usually <5 minutes after DNS propagates). Do not proceed until verified.
- [ ] 1.5 Create a Resend API key scoped to the `mealie.jenkinz.net` sender domain: Dashboard → API Keys → Create. Name `mealie-prod-smtp`. Permission: "Sending access" (not full). Save to 1Password as "Resend – API key (mealie-prod)".
- [ ] 1.6 Confirm Resend's SMTP endpoint matches the chart defaults we'll ship: host `smtp.resend.com`, port `587`, auth `TLS (STARTTLS)`, username `resend`, password = the API key. If Resend changes these in the future, the chart values can be overridden without structural changes.

## 2. Chart — values shape

- [x] 2.1 Add an `email:` block to `helm/mealie/values.yaml` with safe disabled defaults: `enabled: false`, `host: ""`, `port: 587`, `fromName: "Mealie"`, `fromEmail: ""`, `authStrategy: "TLS"`, `existingSecret: "mealie-smtp"`. Add a brief comment explaining that credentials come from the external Secret, not from values.
- [x] 2.2 Do NOT change `helm/values/dev.yaml` — dev stays with the default `email.enabled: false`.

## 3. Chart — templates

- [x] 3.1 Extend `helm/mealie/templates/configmap.yaml` with a `{{- if .Values.email.enabled }}` block emitting `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM_NAME`, `SMTP_FROM_EMAIL`, `SMTP_AUTH_STRATEGY` from the `email.*` values. Ensure each value is `quote`d so a numeric `SMTP_PORT` is not emitted as a YAML number.
- [x] 3.2 Update the Mealie Deployment template so, when `email.enabled` is true, the main container's `envFrom` list includes `{ secretRef: { name: {{ .Values.email.existingSecret | default "mealie-smtp" }} } }`. When disabled, no such entry is added.
- [x] 3.3 Render with `email.enabled: false` (dev/default) and confirm: no `SMTP_*` keys in the ConfigMap; no `mealie-smtp` reference in the Deployment's `envFrom`.
- [x] 3.4 Render with a local override `email.enabled: true, host: "smtp.example.com", fromEmail: "t@example.com"` and confirm: all five `SMTP_*` keys appear in the ConfigMap with the right values; Deployment has the `envFrom.secretRef` entry.

## 4. Prod values

- [x] 4.1 In `helm/values/prod.yaml`, add an `email:` block:
      ```yaml
      email:
        enabled: true
        host: "smtp.resend.com"
        port: 587
        fromName: "Mealie"
        fromEmail: "no-reply@mealie.jenkinz.net"
        authStrategy: "TLS"
      ```
- [x] 4.2 Do NOT set `existingSecret` in prod values — accept the default (`mealie-smtp`). Keeps prod.yaml minimal.
- [x] 4.3 Confirm by inspection that `helm/values/prod.yaml` contains no `SMTP_USER` or `SMTP_PASSWORD` value.

## 5. Justfile recipe

- [x] 5.1 Add a `smtp-bootstrap` recipe to `justfile` modeled on `backup-bootstrap`. Behavior:
  - Verify env vars `SMTP_USER` and `SMTP_PASSWORD` are set; exit non-zero with a clear message listing missing ones.
  - Verify `~/.kube/mealie-prod.yaml` exists; otherwise exit non-zero pointing at `just vps-kubeconfig`.
  - Use `kubectl create secret generic mealie-smtp --from-literal=SMTP_USER=... --from-literal=SMTP_PASSWORD=... --dry-run=client -o yaml | kubectl apply -f -` so it's idempotent.
  - Scope to namespace `mealie`. Use `KUBECONFIG=~/.kube/mealie-prod.yaml` inline, same pattern as `deploy-prod`.
- [ ] 5.2 Re-run the recipe twice against a test cluster (or prod) with the same inputs — confirm second run is a no-op and exits 0. **[needs prod access]**

## 6. Documentation

- [x] 6.1 Create `k8s/smtp/README.md` covering:
  - Rationale for Resend (summarize design.md's decision table in ~10 lines).
  - Resend signup, domain add, DNS records section with **a concrete example** of what the Cloudflare records should look like (provider values will differ; show the shape).
  - Reminder that DKIM CNAMEs at Cloudflare must be **DNS-only** (orange cloud off).
  - `just smtp-bootstrap` invocation with 1Password-references for the two env vars.
  - Testing delivery: send a password-reset email to a Gmail address and an iCloud address; verify SPF=pass, DKIM=pass in the full headers.
  - Rotating the API key (create new key at Resend, `smtp-bootstrap` with new value, `kubectl -n mealie rollout restart deployment/mealie`, delete old key in Resend).
  - Swapping provider (list of values to change + re-bootstrap, no chart changes needed).
- [x] 6.2 Update root `README.md` — Production Deploy section: add `just smtp-bootstrap` as a one-time step after `just backup-bootstrap`. Mention the DNS prerequisite with a link to `k8s/smtp/README.md`.

## 7. Deploy and verify in prod

- [ ] 7.1 Open a PR with the chart, values, justfile, and docs changes. Review green-field render diffs (dev = unchanged; prod = adds SMTP_* to configmap and envFrom to Deployment).
- [ ] 7.2 Merge to main. Check out main locally.
- [ ] 7.3 Run `just smtp-bootstrap` with `SMTP_USER=resend` and `SMTP_PASSWORD=<resend-api-key-from-1password>`. Confirm the Secret is created: `kubectl -n mealie get secret mealie-smtp -o jsonpath='{.data}'` shows two keys.
- [ ] 7.4 Run `just deploy-prod`. Confirm the rollout picks up the new env vars: `kubectl -n mealie set env deployment/mealie --list | grep SMTP_` shows the five non-secret vars; the container env (after `envFrom`) includes `SMTP_USER` and `SMTP_PASSWORD` from the Secret.
- [ ] 7.5 Create a test user account (or use an existing family member's account with permission). Trigger "forgot password" from the Mealie login page.
- [ ] 7.6 Confirm the email arrives at the test inbox within 2 minutes. Inspect the full headers: SPF=pass, DKIM=pass, `From: Mealie <no-reply@mealie.jenkinz.net>`.
- [ ] 7.7 Click the reset link, set a new password, log in with it. End-to-end success.
- [ ] 7.8 (Negative test) In a scratch test: flip `email.enabled: false` in a local copy of prod values and render — confirm SMTP_* keys are absent. Don't actually deploy this; it's just to verify the rollback lever works.

## 8. Archive

- [ ] 8.1 Once all tasks above are checked and the acceptance test in 7.5–7.7 has been observed at least twice (once for password reset, once for a real household invitation flow — see 8.2), run `/opsx:archive add-email-smtp`.
- [ ] 8.2 Send a real household invitation from Admin UI to a second family head's email; confirm delivery + successful account creation via the invite link. This validates the invitation flow, not just password reset.
- [ ] 8.3 Update the hosting plan memory: mark phase 7 (`add-email-smtp`) complete, leave phase 8 (`add-grafana-cloud-agent`) as the next one.
