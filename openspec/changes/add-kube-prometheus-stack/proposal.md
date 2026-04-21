# Change: Self-Hosted Monitoring via kube-prometheus-stack (Phase 8, take two)

## Why

This replaces the abandoned `add-grafana-cloud-agent` change. Mid-way through
implementing the hosted-SaaS design, the underlying tradeoff got revisited
honestly and flipped.

The original case for Grafana Cloud rested on one headline number — **"in-cluster
Prometheus eats ~18% of 8 GB"**. That number came from kube-prometheus-stack's
out-of-box config: 30-day retention, every operator CRD enabled, the full
bundle. A **tuned, family-scale install** (7-day retention, no Thanos, no
PodMonitors for workloads we don't run) lands around **900 MB** — comfortable
within the ~6 GB free on the CX33 after Mealie + Postgres + K3s system pods +
cert-manager + backup CronJob. The RAM argument didn't survive actually
sizing it.

With that constraint gone, the learning argument flips. Running Alloy →
Grafana Cloud teaches *remote_write URL configuration*. Running Prometheus +
Grafana + Alertmanager in-cluster teaches the entire observability stack:
PromQL against real storage, Alertmanager routing + templating, Grafana
dashboard provisioning, ServiceMonitor / PrometheusRule CRDs (the standard
K8s-ops pattern used at most shops). That's core skill-building that matches
the hosting plan's stated goal of *"hands-on K8s learning"*.

Secondary benefits that came along for free once the RAM blocker dissolved:

- **One less SaaS account** — no Grafana Cloud token rotation, no UI
  reshuffle surprises (already hit one during the pivot), no "what happens
  if the account lapses."
- **Data stays on our VPS** — logs never leave the infrastructure we control.
- **Alert delivery reuses phase 7 infrastructure** — Alertmanager sends via
  the existing Resend SMTP setup; no new outbound dependency.

One real tradeoff remains: **the cluster can't self-alert if the whole
cluster is down**. Mitigation is a single external Uptime Robot check
(free tier, 5-min interval) hitting `https://mealie.jenkinz.net/api/app/about`.
Documented as a 5-minute out-of-band setup in the runbook.

## What Changes

### Chart dependencies

- `helm/mealie/Chart.yaml`: **replace** the two observability deps from the
  abandoned change (`grafana/alloy`, `prometheus-community/kube-state-metrics`)
  with a single **`prometheus-community/kube-prometheus-stack`** dep. The
  stack already bundles kube-state-metrics, node-exporter, Prometheus,
  Alertmanager, Grafana, and the prometheus-operator. Pin a current stable
  version; update `Chart.lock` accordingly.

### Subchart configuration

- `helm/mealie/values.yaml`: **rewrite** the `observability:` block. New
  shape:
  ```yaml
  observability:
    enabled: false
    grafana:
      host: "grafana.local"                   # dev default; prod overrides
      existingSecret: "grafana-admin"
      storage: 2Gi
    prometheus:
      retention: "7d"
      storage: 10Gi
    alertmanager:
      storage: 1Gi
      smtpFromAddress: "alerts@mealie.jenkinz.net"
      smtpToAddress:   "andygjenkins@gmail.com"
      existingSmtpSecret: "mealie-smtp"       # reuses phase 7 Secret
    # postgres-exporter sidecar config (unchanged shape from abandoned change)
    postgresExporter:
      image: { repository: quay.io/prometheuscommunity/postgres-exporter, tag: "v0.15.0" }
      resources: { requests: { memory: 32Mi, cpu: 20m }, limits: { memory: 64Mi, cpu: 100m } }

  # Subchart overrides (only read when observability.enabled)
  kube-prometheus-stack:
    prometheus:
      prometheusSpec:
        retention: 7d
        resources: { requests: { memory: 400Mi, cpu: 100m }, limits: { memory: 800Mi, cpu: 1000m } }
        storageSpec: …              # 10 Gi PVC via volumeClaimTemplate
        # Watch ServiceMonitors in all namespaces (we put ours in mealie ns)
        serviceMonitorSelectorNilUsesHelmValues: false
        podMonitorSelectorNilUsesHelmValues:    false
        ruleSelectorNilUsesHelmValues:          false
    grafana:
      admin:
        existingSecret: "grafana-admin"
        userKey: admin-user
        passwordKey: admin-password
      persistence: { enabled: true, size: 2Gi }
      sidecar:
        dashboards:
          enabled: true
          label: grafana_dashboard
          searchNamespace: ALL
      ingress:  …                             # rendered from our values
    alertmanager:
      alertmanagerSpec:
        resources: { requests: { memory: 64Mi, cpu: 20m }, limits: { memory: 128Mi, cpu: 200m } }
        storage:   …                          # 1 Gi PVC
      config: …                               # SMTP route, receivers from values
  ```

### New chart templates

- `helm/mealie/templates/service-monitors.yaml` — **NEW.** ServiceMonitor
  resources (one per target) for `postgres-exporter`, Traefik (in
  `kube-system`), cert-manager (in its own namespace). All gated by
  `observability.enabled`.
- `helm/mealie/templates/prometheus-rules.yaml` — **NEW.** A single
  `PrometheusRule` resource containing all five alerts
  (mealie-not-ready, no-recent-backup, pvc-filling, tls-expiring,
  postgres-down). Uses the operator-provided CRD, so Prometheus auto-loads
  them. Gated by `observability.enabled`.
- `helm/mealie/templates/grafana-dashboard-mealie.yaml` — **NEW.** A
  ConfigMap wrapping `k8s/observability/dashboards/mealie-overview.json`
  (retained from the abandoned change), labeled `grafana_dashboard=1` so
  the Grafana sidecar auto-imports it.
- `helm/mealie/templates/grafana-ingress.yaml` — **NEW.** Separate Ingress
  resource for `grafana.jenkinz.net`, wired to cert-manager + Traefik like
  the Mealie Ingress.

### Modified chart templates

- `helm/mealie/templates/postgres-deployment.yaml` — **keep** the
  postgres-exporter sidecar and its `metrics` port. **Drop** the
  `prometheus.io/scrape` pod annotations (no longer needed — ServiceMonitor
  replaces annotation-based discovery). Add a matching Service with the
  `app.kubernetes.io/component: metrics-exporter` label so the
  ServiceMonitor can select on it.
- `helm/mealie/templates/alloy-config.yaml` — **DELETE.**

### Prod values

- `helm/values/prod.yaml`: `observability.enabled: true`,
  `grafana.host: "grafana.jenkinz.net"`, retention + storage sized for prod,
  Alertmanager SMTP config pointing at the existing `mealie-smtp` Secret,
  ingress class + cert-manager annotations for Grafana.

### Secrets

One new Secret `grafana-admin` in the `mealie` namespace with two keys
(`admin-user`, `admin-password`), created by `just grafana-admin-bootstrap`.
The existing `mealie-smtp` Secret (from phase 7) is referenced directly by
Alertmanager — **no duplication**, same Resend credentials.

### Justfile

- **Remove** the abandoned `grafana-bootstrap` recipe from the
  add-grafana-cloud-agent change (it created a 4-key Grafana Cloud Secret
  that this change no longer needs).
- **Add** `grafana-admin-bootstrap` — creates/updates the `grafana-admin`
  Secret from `GRAFANA_ADMIN_USER` + `GRAFANA_ADMIN_PASSWORD` env vars.
  Idempotent. Same pattern as backup / smtp bootstrap.

### Runbook

- `k8s/observability/README.md` — **rewrite.** Covers: architecture overview
  (what each component does and why it's in-cluster), Cloudflare DNS
  one-time record for `grafana.jenkinz.net`, Uptime Robot setup for
  external reachability monitoring, `grafana-admin-bootstrap` flow,
  verifying the pipeline (a PromQL sanity query from inside Grafana),
  how to edit alerts (PrometheusRule YAML → PR → deploy), how to add
  dashboards (ConfigMap + label, auto-imports), and a troubleshooting
  section (pods not Ready, OOMs under real load, PVC filling,
  Alertmanager not delivering email).

### Dashboards + alerts

- `k8s/observability/dashboards/mealie-overview.json` — **keep** from the
  abandoned change (the JSON is Grafana-native; works against
  self-hosted just as well as hosted). Now auto-loaded via the ConfigMap
  sidecar.
- `k8s/observability/alerts/` — **NEW** optional directory if we want to
  keep PrometheusRule YAML source alongside the Helm template; in
  practice the Helm template is probably sufficient. Decide during apply.
- Upstream integration dashboards (Kubernetes, PostgreSQL, node-exporter,
  prometheus itself) come bundled with kube-prometheus-stack's Grafana
  defaults — no extra work.

### Root README

- `README.md`: swap phase 8 line from Grafana Cloud to self-hosted
  kube-prometheus-stack. Update the first-time-deploy checklist step 8
  accordingly.

### Abandoned-change cleanup

- `openspec/changes/add-grafana-cloud-agent/`: **delete** the entire
  change directory as part of this change's tasks. It was never
  implemented end-to-end (some chart code landed, which this change
  also undoes). An entry in `openspec/changes/archive/` is inappropriate
  because the change was abandoned, not completed; the record of the
  pivot lives in this change's `proposal.md` + updated hosting-plan
  memory.

## Capabilities

### New Capabilities

- `observability`: Shipping cluster + Mealie-specific metrics to
  in-cluster Prometheus, rendering them in in-cluster Grafana, and
  alerting via in-cluster Alertmanager → Resend SMTP. Plus external
  reachability monitoring via Uptime Robot. Includes the chart wiring,
  the `grafana-admin` Secret shape, the bootstrap recipe, alert-as-code
  contracts (PrometheusRule CRD), and the version-controlled overview
  dashboard.

*(Same capability name as the abandoned change. The `specs/observability/spec.md`
in this change authoritatively defines the capability on archive — the
abandoned-change directory is deleted before that ever happens, so there's
no duplicate-spec collision.)*

### Modified Capabilities

None.

## Impact

- **New capability spec**: `observability`.
- **New files**:
  - `helm/mealie/templates/service-monitors.yaml`
  - `helm/mealie/templates/prometheus-rules.yaml`
  - `helm/mealie/templates/grafana-dashboard-mealie.yaml`
  - `helm/mealie/templates/grafana-ingress.yaml`
- **Touches**:
  - `helm/mealie/Chart.yaml` (swap deps), `Chart.lock` (regenerated)
  - `helm/mealie/values.yaml` (rewrite observability block)
  - `helm/mealie/templates/postgres-deployment.yaml` (drop pod annotations,
    add metrics Service)
  - `helm/values/prod.yaml` (rewrite observability block)
  - `justfile` (swap `grafana-bootstrap` → `grafana-admin-bootstrap`)
  - `README.md` (phase 8 + first-time-deploy step 8)
  - `k8s/observability/README.md` (rewrite)
  - `k8s/observability/dashboards/mealie-overview.json` (unchanged content)
  - `k8s/observability/traefik-metrics.yaml` (unchanged; still applied
    out-of-band as a K3s HelmChartConfig)
- **Deletes**:
  - `helm/mealie/templates/alloy-config.yaml`
  - `openspec/changes/add-grafana-cloud-agent/` (entire directory)
- **New external dependency**: Uptime Robot free account.
- **New cluster resources**: one Ingress (grafana.jenkinz.net), one PVC
  each for Prometheus / Grafana / Alertmanager, two DaemonSets (node-exporter
  from the stack, prometheus-operator), plus the usual stack pods.
- **New DNS record** (out-of-band at Cloudflare): `A` or `CNAME`
  `grafana.jenkinz.net` → same IP as `mealie.jenkinz.net` (same Traefik
  handles both).
- **Resource cost on VPS**: ~900 Mi memory / ~500 m CPU steady-state across
  the whole stack. Well inside the CX33's headroom.
- **Cost impact**: $0/month. Uptime Robot free tier covers the 1 check we
  need with plenty of margin (free tier: 50 monitors, 5-min interval).

## Out of Scope (deferred)

- **Log aggregation (Loki/Promtail).** Future `add-loki` change if/when
  `kubectl logs` stops being enough. Not blocking this change.
- **Tracing (Tempo).** No application tracing instrumentation in Mealie
  anyway.
- **Prometheus HA / federation.** Single replica is fine at this scale.
- **Long-term storage (Thanos, Mimir).** 7-day retention on a single
  Prometheus instance is the right size for a family app.
- **Grafana OIDC / SSO / multi-user RBAC.** Solo admin for now.
- **External secret management** (sealed-secrets / External Secrets
  Operator). Manual bootstrap stays; revisit when >3 Secrets to manage.
- **Alert-as-code tooling** beyond the native PrometheusRule CRD
  (Grizzly, Mimirtool rules files). The CRD alone is sufficient at this
  scale.
- **Synthetic probing from inside the cluster.** Uptime Robot covers
  external reachability, which is the signal that actually matters.
