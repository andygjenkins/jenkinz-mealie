# Email Notifications Specification

## ADDED Requirements

### Requirement: Opt-In SMTP per Environment
The Helm chart SHALL expose an `email.enabled` flag that controls whether any
SMTP configuration reaches the Mealie pod. Dev environments SHALL default to
disabled; prod SHALL enable it.

#### Scenario: Dev renders with SMTP absent
- **WHEN** the chart is rendered against `helm/values/dev.yaml` (or defaults)
- **THEN** `email.enabled` is `false`
- **AND** the rendered ConfigMap does **not** contain `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM_NAME`, `SMTP_FROM_EMAIL`, or `SMTP_AUTH_STRATEGY`
- **AND** the rendered Deployment does **not** reference the `mealie-smtp` Secret in `envFrom`

#### Scenario: Prod renders with SMTP enabled
- **WHEN** the chart is rendered against `helm/values/prod.yaml`
- **THEN** `email.enabled` is `true`
- **AND** `email.host` is `smtp.resend.com`
- **AND** `email.port` is `587`
- **AND** `email.fromEmail` is `no-reply@mealie.jenkinz.net`
- **AND** `email.authStrategy` is `TLS`
- **AND** the rendered ConfigMap contains `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM_NAME`, `SMTP_FROM_EMAIL`, `SMTP_AUTH_STRATEGY` with those values
- **AND** the rendered Deployment includes an `envFrom.secretRef` entry pointing at `mealie-smtp`

### Requirement: Credentials Sourced From an External Secret
SMTP credentials (`SMTP_USER`, `SMTP_PASSWORD`) SHALL live in a Kubernetes
Secret named `mealie-smtp` in the `mealie` namespace, created out-of-band by
`just smtp-bootstrap`. Credentials SHALL NOT appear in `helm/values/prod.yaml`
or be passed via `helm --set`.

#### Scenario: prod.yaml contains no SMTP credentials
- **WHEN** `helm/values/prod.yaml` is inspected
- **THEN** no key named `smtpUser`, `smtpPassword`, `SMTP_USER`, or `SMTP_PASSWORD` holds a non-empty value

#### Scenario: Deployment consumes the external Secret
- **WHEN** the chart is rendered with `email.enabled: true`
- **THEN** the Mealie Deployment's `envFrom` references a Secret by the name `email.existingSecret` (default `mealie-smtp`)
- **AND** no SMTP credential is inlined into the rendered Deployment, ConfigMap, or release Secret

### Requirement: Bootstrap Recipe Creates the SMTP Secret
The repository SHALL provide a `just smtp-bootstrap` recipe that creates or
updates the `mealie-smtp` Secret in the `mealie` namespace from env vars
`SMTP_USER` and `SMTP_PASSWORD`.

#### Scenario: Bootstrap creates the Secret
- **WHEN** a developer runs `just smtp-bootstrap` with both `SMTP_USER` and `SMTP_PASSWORD` set, against the prod kubeconfig
- **THEN** a Secret named `mealie-smtp` exists in the `mealie` namespace
- **AND** it contains exactly two keys: `SMTP_USER` and `SMTP_PASSWORD`
- **AND** re-running the recipe with the same inputs is a no-op (exits 0, idempotent)

#### Scenario: Bootstrap fails fast without credentials
- **WHEN** `just smtp-bootstrap` runs with `SMTP_USER` or `SMTP_PASSWORD` unset
- **THEN** the command exits non-zero with a message naming the missing variable
- **AND** no Secret is created or modified

#### Scenario: Bootstrap fails without prod kubeconfig
- **WHEN** `just smtp-bootstrap` runs and `~/.kube/mealie-prod.yaml` does not exist
- **THEN** the recipe exits non-zero with a message referencing `just vps-kubeconfig`
- **AND** no `kubectl` action is taken

### Requirement: Deploy Recipe Unchanged by SMTP
`just deploy-prod` SHALL NOT require any SMTP-related env vars or
`--set` flags. The Secret is referenced by name in the chart and picked up
by the pod via `envFrom` on the next rollout.

#### Scenario: Deploy-prod env-var surface unchanged
- **WHEN** `just deploy-prod` is invoked with only `MEALIE_SECRET_KEY` and `POSTGRES_PASSWORD` set
- **THEN** the recipe runs successfully and applies the chart
- **AND** it does not require `SMTP_USER`, `SMTP_PASSWORD`, or any other SMTP-related env var
- **AND** it does not pass any `--set` flag referencing `email.*` or `smtp.*`

### Requirement: Password Reset Emails Deliver End-to-End
With SMTP enabled and the `mealie-smtp` Secret bootstrapped in prod, the
password-reset flow SHALL send an email that arrives at the recipient inbox
and contains a working reset link.

#### Scenario: Password reset email is received
- **WHEN** an admin triggers "forgot password" for a test user in prod
- **THEN** the Mealie pod logs a successful SMTP send (no SMTP error)
- **AND** an email from `no-reply@mealie.jenkinz.net` arrives at the test user's inbox within 2 minutes
- **AND** the email passes SPF and DKIM checks at the receiving server

#### Scenario: Reset link completes the flow
- **WHEN** the test user clicks the reset link from the received email
- **AND** submits a new password on the reset page
- **THEN** the password is updated
- **AND** the user can log in with the new password

### Requirement: Runbook Documents Provider Setup and DNS
A runbook SHALL document the one-time provider setup (Resend signup, sender
domain verification) and the DNS records that must be added at Cloudflare
for `mealie.jenkinz.net`, plus bootstrap and rotation procedures.

#### Scenario: Runbook covers the lifecycle
- **WHEN** a developer opens `k8s/smtp/README.md`
- **THEN** the document describes: Resend signup, sender domain add, the exact DNS records (SPF TXT, DKIM CNAMEs, optional DMARC) with expected values, generating a scoped API key, running `just smtp-bootstrap`, testing delivery to at least one external inbox, rotating the API key, and swapping to a different provider (SES, Gmail app password) without chart changes
