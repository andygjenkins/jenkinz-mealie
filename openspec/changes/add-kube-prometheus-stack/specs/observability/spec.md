# Observability Specification

## ADDED Requirements

### Requirement: Opt-In Observability per Environment
The Helm chart SHALL expose an `observability.enabled` flag that controls
whether the kube-prometheus-stack subchart and all observability-related
resources are rendered. Dev environments SHALL default to disabled; prod
SHALL enable it.

#### Scenario: Dev renders without observability resources
- **WHEN** the chart is rendered against `helm/values/dev.yaml` (or defaults)
- **THEN** `observability.enabled` is `false`
- **AND** no Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics,
  prometheus-operator, ServiceMonitor, PrometheusRule, Grafana Ingress, or
  Grafana admin Secret references appear in the rendered output
- **AND** no postgres-exporter sidecar appears on the Postgres StatefulSet

#### Scenario: Prod renders with the full stack
- **WHEN** the chart is rendered against `helm/values/prod.yaml`
- **THEN** `observability.enabled` is `true`
- **AND** the rendered output includes Deployments/StatefulSets for
  Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics,
  and prometheus-operator
- **AND** an Ingress for `grafana.jenkinz.net` is rendered with the
  `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation
- **AND** a ServiceMonitor for the postgres-exporter sidecar is rendered
- **AND** a PrometheusRule containing five alert rules is rendered
- **AND** a ConfigMap labeled `grafana_dashboard=1` wrapping the Mealie
  overview dashboard is rendered

### Requirement: Grafana Admin Credentials in an External Secret
Grafana admin credentials SHALL live in a Kubernetes Secret named
`grafana-admin` in the `mealie` namespace, containing keys `admin-user`
and `admin-password`, created out-of-band by `just grafana-admin-bootstrap`.
Credentials SHALL NOT appear in any values file or be passed via `helm --set`.

#### Scenario: prod.yaml contains no Grafana admin credentials
- **WHEN** `helm/values/prod.yaml` is inspected
- **THEN** no key named `adminUser`, `adminPassword`, `admin-user`,
  `admin-password`, or `grafana.admin.password` holds a non-empty value

#### Scenario: Grafana consumes the external Secret
- **WHEN** the chart is rendered with `observability.enabled: true`
- **THEN** the Grafana subchart values reference the Secret name from
  `observability.grafana.existingSecret` (default `grafana-admin`) and the
  keys `admin-user` / `admin-password`

### Requirement: Bootstrap Recipe Creates the Grafana Admin Secret
The repository SHALL provide a `just grafana-admin-bootstrap` recipe that
creates or updates the `grafana-admin` Secret from env vars
`GRAFANA_ADMIN_USER` and `GRAFANA_ADMIN_PASSWORD`.

#### Scenario: Bootstrap creates the Secret
- **WHEN** a developer runs `just grafana-admin-bootstrap` with both env
  vars set, against the prod kubeconfig
- **THEN** a Secret named `grafana-admin` exists in the `mealie` namespace
- **AND** it contains exactly the two keys `admin-user` and `admin-password`
- **AND** re-running with the same inputs is a no-op and exits 0

#### Scenario: Bootstrap fails fast without credentials
- **WHEN** `just grafana-admin-bootstrap` runs with either env var unset
- **THEN** the command exits non-zero with a message naming the missing
  variable(s)
- **AND** no Secret is created or modified

#### Scenario: Bootstrap fails without prod kubeconfig
- **WHEN** `just grafana-admin-bootstrap` runs and `~/.kube/mealie-prod.yaml`
  does not exist
- **THEN** the recipe exits non-zero with a message referencing
  `just vps-kubeconfig`
- **AND** no `kubectl` action is taken

### Requirement: Alertmanager Uses the Existing mealie-smtp Secret
Alertmanager SHALL send emails via the existing Resend SMTP configuration
from phase 7 by referencing the `mealie-smtp` Secret in the `mealie`
namespace. The observability change SHALL NOT introduce a duplicate SMTP
credential.

#### Scenario: Alertmanager config references the shared SMTP Secret
- **WHEN** the chart is rendered with `observability.enabled: true`
- **THEN** the Alertmanager configuration references `mealie-smtp` as its
  SMTP credentials source (via envFrom, config-volume secret reference, or
  Alertmanager's native `auth_password_file` pattern, whichever the
  subchart supports cleanly)
- **AND** no key named `SMTP_PASSWORD` or equivalent appears as a literal
  value in the rendered Alertmanager Secret or ConfigMap

#### Scenario: Alert email delivery end-to-end
- **WHEN** an alert fires (e.g. via the induced test in the runbook)
- **THEN** Alertmanager logs a successful SMTP send (no auth / TLS errors)
- **AND** an email arrives at `andygjenkins@gmail.com` from
  `alerts@mealie.jenkinz.net` within 2 minutes
- **AND** the email passes SPF + DKIM at the receiving server (inherited
  from the phase 7 Resend domain setup — no new DNS required)

### Requirement: Grafana Exposed at grafana.jenkinz.net with TLS
The chart SHALL render an Ingress resource that exposes Grafana at
`grafana.jenkinz.net` via the existing Traefik + cert-manager setup.

#### Scenario: Grafana Ingress annotated for cert-manager
- **WHEN** the chart is rendered with `observability.enabled: true`
- **THEN** the Grafana Ingress has the annotation
  `cert-manager.io/cluster-issuer: letsencrypt-prod`
- **AND** the Ingress host is `grafana.jenkinz.net`
- **AND** the TLS block references a Secret for that host

#### Scenario: HTTPS returns 200
- **WHEN** Grafana is deployed and the cert-manager Certificate has
  reached Ready
- **AND** `curl -sS -o /dev/null -w "%{http_code}" https://grafana.jenkinz.net/api/health`
  is executed
- **THEN** the response code is `200`
- **AND** the TLS chain validates against the public Let's Encrypt roots

### Requirement: Five Alerts Defined as PrometheusRule Custom Resources
The chart SHALL ship exactly five alerts as a single PrometheusRule
resource in the `mealie` namespace, picked up automatically by the
prometheus-operator.

#### Scenario: PrometheusRule is rendered with five alerts
- **WHEN** the chart is rendered with `observability.enabled: true`
- **THEN** exactly one `PrometheusRule` resource is present
- **AND** it contains rule groups with five distinct alerts named
  `MealieDeploymentNotReady`, `NoRecentMealieBackup`, `MealiePVCFilling`,
  `MealieTLSExpiring`, `MealiePostgresDown`
- **AND** each alert has a `for:` duration, a `severity` label, and a
  `summary` annotation

#### Scenario: Prometheus loads the rule without errors
- **WHEN** the chart is deployed to the prod cluster
- **AND** the prometheus-operator has reconciled the PrometheusRule
- **THEN** the Prometheus `/rules` endpoint lists all five alerts as
  loaded (state `inactive`, `pending`, or `firing`)
- **AND** the metric `prometheus_rule_group_last_evaluation_errors_total`
  for the group stays at 0

#### Scenario: Each alert fires when its condition is induced
- **WHEN** the operator intentionally induces the condition for each
  alert (scale Mealie to 0, pause the backup Job, fill the PVC, etc.)
- **THEN** within the alert's `for:` duration, an email from
  `alerts@mealie.jenkinz.net` arrives at `andygjenkins@gmail.com` naming
  the alert
- **AND** when the condition is resolved, the alert auto-resolves and a
  `[RESOLVED]` email is sent

### Requirement: ServiceMonitors for In-Chart Scrape Targets
The chart SHALL render ServiceMonitor resources for each in-chart exporter
(postgres-exporter sidecar) and for cluster-infrastructure targets that
don't ship their own (Traefik in kube-system).

#### Scenario: postgres-exporter ServiceMonitor
- **WHEN** the chart is rendered with `observability.enabled: true`
- **THEN** a ServiceMonitor named `mealie-postgres-exporter` is present
- **AND** its selector matches the Service fronting the postgres-exporter
  sidecar on the mealie-postgres StatefulSet
- **AND** its `endpoints[].port` is `metrics` (mapped to container port 9187)

#### Scenario: Traefik ServiceMonitor
- **WHEN** the chart is rendered with `observability.enabled: true` in prod
- **THEN** a ServiceMonitor that selects the `traefik` Service in
  `kube-system` is present
- **AND** its endpoint scrapes the `metrics` port enabled by
  `k8s/observability/traefik-metrics.yaml`

### Requirement: Mealie Overview Dashboard Auto-Imported
The chart SHALL render a ConfigMap wrapping
`k8s/observability/dashboards/mealie-overview.json` with the label
`grafana_dashboard=1`, so Grafana's sidecar auto-imports it.

#### Scenario: Dashboard ConfigMap labeled for sidecar
- **WHEN** the chart is rendered with `observability.enabled: true`
- **THEN** a ConfigMap containing the dashboard JSON is present
- **AND** it carries the label `grafana_dashboard: "1"`
- **AND** its `data` section contains exactly one key whose value is
  valid Grafana-importable JSON

#### Scenario: Dashboard appears in Grafana within 5 minutes of deploy
- **WHEN** the chart is deployed to prod
- **AND** 5 minutes have passed
- **THEN** a dashboard named "Mealie Overview" exists in Grafana at
  `https://grafana.jenkinz.net`
- **AND** all panels populate with data (no "No data" states persisting
  past the initial scrape interval)

### Requirement: External Reachability Check Covers VPS-Down Scenario
The runbook SHALL document a single Uptime Robot free-tier HTTP check
against `https://mealie.jenkinz.net/api/app/about`, alerting to
`andygjenkins@gmail.com`, serving as the out-of-cluster reachability
signal.

#### Scenario: Runbook covers the external check setup
- **WHEN** a developer opens `k8s/observability/README.md`
- **THEN** the document describes: Uptime Robot signup, creating one
  HTTP check with exact URL and 5-min interval, adding the email alert
  contact, expected email subject line, and the rationale (in-cluster
  monitoring can't catch VPS-down)

### Requirement: Resource Budget Respected
The total memory request across all observability workloads (Prometheus,
Grafana, Alertmanager, node-exporter, kube-state-metrics, prometheus-operator,
postgres-exporter sidecar) SHALL NOT exceed 1 Gi; the total memory limit
SHALL NOT exceed 2 Gi.

#### Scenario: Resource requests and limits are within budget
- **WHEN** the chart is rendered with `observability.enabled: true`
- **THEN** the sum of `resources.requests.memory` across all observability
  containers is ≤ 1 Gi
- **AND** the sum of `resources.limits.memory` is ≤ 2 Gi

### Requirement: Runbook for Self-Hosted Observability
A runbook SHALL document: architecture overview, Cloudflare DNS record
for `grafana.jenkinz.net`, Uptime Robot external-check setup,
`just grafana-admin-bootstrap` flow, pipeline verification (sanity PromQL
query + Grafana login), how to edit or add PrometheusRule alerts, how to
add a new Grafana dashboard (ConfigMap + label), how to rotate the
Grafana admin password, and troubleshooting guidance for common failure
modes (pods not Ready, OOMs, PVC full, Alertmanager not sending).

#### Scenario: Runbook covers the lifecycle
- **WHEN** a developer opens `k8s/observability/README.md`
- **THEN** the document contains sections for: architecture,
  one-time setup (Cloudflare DNS + Uptime Robot + admin Secret
  bootstrap + traefik-metrics application), deploy + verify, alerts
  (PrometheusRule editing), dashboards (ConfigMap + label pattern),
  rotation, and troubleshooting
- **AND** each section has either commands to run or a short narrative
  with concrete file paths
