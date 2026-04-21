# Tasks: Self-Hosted Monitoring via kube-prometheus-stack (Phase 8, take two)

## 1. Clean up the abandoned Grafana Cloud implementation

The workspace contains partial `add-grafana-cloud-agent` code. Remove what
doesn't survive the pivot before adding the new stack.

- [x] 1.1 Delete `helm/mealie/templates/alloy-config.yaml`.
- [x] 1.2 In `helm/mealie/Chart.yaml`, remove the `grafana/alloy` and `prometheus-community/kube-state-metrics` subchart dependencies added by the abandoned change.
- [x] 1.3 Delete the corresponding `.tgz` archives and Chart.lock (regenerated in 3.3).
- [x] 1.4 In `helm/mealie/values.yaml`, deleted the abandoned `observability:`, `alloy:`, `kube-state-metrics:` blocks.
- [x] 1.5 In `helm/values/prod.yaml`, deleted the `observability:` block with the `remoteWriteUrl` / `pushUrl` placeholders.
- [x] 1.6 Removed the `grafana-bootstrap` recipe from `justfile`.
- [x] 1.7 Removed the `prometheus.io/scrape` annotations from postgres-deployment.yaml. Sidecar container kept.
- [x] 1.8 Removed phase-8 / step-8 Grafana Cloud blurbs from root `README.md`.
- [x] 1.9 Deleted `openspec/changes/add-grafana-cloud-agent/` directory.
- [x] 1.10 Disabled render = 0 observability references (verified after task 4.3 since task 1.10's own check required the new observability values block to be in place; task 4.3 confirms).

## 2. Traefik metrics HelmChartConfig (if not already applied)

`k8s/observability/traefik-metrics.yaml` exists from the abandoned change
and is still needed — ServiceMonitor-based scraping reads from the same
`:9100/metrics` endpoint. Re-confirm it's in place.

- [x] 2.1 Verified file present at `k8s/observability/traefik-metrics.yaml`.
- [ ] 2.2 Apply to prod: `KUBECONFIG=~/.kube/mealie-prod.yaml kubectl apply -f k8s/observability/traefik-metrics.yaml`. **[needs prod access]**
- [ ] 2.3 Verify Traefik still serves the public site. **[needs prod access]**

## 3. Add the kube-prometheus-stack dependency

- [x] 3.1 Added `prometheus-community/kube-prometheus-stack` version `83.6.0` (current latest stable, Prom operator `v0.90.1`) to `Chart.yaml`, gated by `observability.enabled`.
- [x] 3.2 Prometheus Community repo registered.
- [x] 3.3 `helm dep update` succeeded; new `Chart.lock` generated. Two subcharts: `postgresql-16.4.1.tgz`, `kube-prometheus-stack-83.6.0.tgz`.
- [x] 3.4 Verified: only postgresql + kube-prometheus-stack deps present. No alloy or standalone kube-state-metrics.

## 4. Chart values: new observability block and subchart overrides

- [x] 4.1 Added `observability:` block to `helm/mealie/values.yaml`: `enabled: false`, `cluster: mealie-dev`, `grafana.host`, `grafana.existingSecret: grafana-admin`, `prometheus.retention: 7d`, `alertmanager.{smtpFromAddress,smtpToAddress,existingSmtpSecret: mealie-smtp}`, `postgresExporter` sidecar config.
- [x] 4.2 Added top-level `kube-prometheus-stack:` subchart-overrides block with:
      - Disable the parts we don't need: `defaultRules.create: false` (we ship our own PrometheusRule), `thanosRuler.enabled: false`, `prometheusOperator.admissionWebhooks` defaults OK.
      - Prometheus: retention 7d; PVC 10Gi; resource requests 400Mi/100m, limits 800Mi/1000m; `serviceMonitorSelectorNilUsesHelmValues: false` (watch all SMs), ditto for PodMonitor and Rule selectors.
      - Alertmanager: PVC 1Gi; resource requests 64Mi/20m, limits 128Mi/200m; config block with `receivers`, `route`, `templates` — SMTP fields reference the shared `mealie-smtp` Secret via `smtp_auth_username_file` / `smtp_auth_password_file` or envFrom pattern (decide at template time which the subchart supports cleanly; Alertmanager historically prefers config-file references).
      - Grafana: `admin.existingSecret: {{ .Values.observability.grafana.existingSecret }}`; PVC 2Gi; `sidecar.dashboards.enabled: true`, label `grafana_dashboard`, `searchNamespace: ALL`; `ingress:` block rendered from our values.
      - node-exporter: resource caps (~30Mi/20m req, 100Mi/200m lim).
      - kube-state-metrics: resource caps (~50Mi/50m req, 128Mi/200m lim).
      - prometheus-operator: resource caps (~100Mi/50m req, 200Mi/200m lim).
- [x] 4.3 Render verified: disabled = 0 observability refs; prod = Prometheus + Grafana + Alertmanager + kube-state-metrics + node-exporter + operator + our 2 ServiceMonitors + PrometheusRule + dashboard ConfigMap + Grafana Ingress all present.

## 5. New chart templates

- [x] 5.1 `helm/mealie/templates/service-monitors.yaml` created. Gated by `observability.enabled`. Contains:
      - A Service named `mealie-postgres-exporter` (ClusterIP) targeting the postgres-exporter sidecar on port 9187 with label `app.kubernetes.io/component: metrics-exporter`.
      - A ServiceMonitor `mealie-postgres-exporter` selecting that Service, port `metrics`, scrape interval 30s.
      - A ServiceMonitor for Traefik in `kube-system` (selector matching the Service created by the K3s-bundled Traefik chart; use `namespaceSelector: matchNames: [kube-system]`; port `metrics`).
      - Optional: a ServiceMonitor for cert-manager if it doesn't self-ship one in the prod install. Check at render time — if it does, skip.
- [x] 5.2 `helm/mealie/templates/prometheus-rules.yaml` created. Single `PrometheusRule` with a single group containing the five alerts:
      - `MealieDeploymentNotReady` (for 5m, severity critical)
      - `NoRecentMealieBackup` (for 15m, severity high)
      - `MealiePVCFilling` (for 30m, severity high)
      - `MealieTLSExpiring` (for 1h, severity medium)
      - `MealiePostgresDown` (for 5m, severity critical)
      Each with expr, `for:`, labels `{severity: …, app: mealie}`, and `annotations: { summary: "…", description: "…" }` using Go templating to interpolate pod/pvc labels where useful.
- [x] 5.3 `helm/mealie/templates/grafana-dashboard-mealie.yaml` created. **Decision taken**: moved the dashboard JSON from `k8s/observability/dashboards/` to `helm/mealie/dashboards/mealie-overview.json` so `.Files.Get` can load it. Single authoritative copy, no drift. Runbook's "Adding a dashboard" section now points at `helm/mealie/dashboards/` as the home for dashboard JSON.
- [x] 5.4 `helm/mealie/templates/grafana-ingress.yaml` created. Ingress for `{{ .Values.observability.grafana.host }}` with cert-manager + Traefik annotations; TLS secret `grafana-tls`; backend `{{ .Release.Name }}-grafana:80`.
- [x] 5.5 All four templates render cleanly against prod.yaml (Alertmanager config decodes to correct SMTP settings with `smtp_auth_{username,password}_file` pointing at the mounted `mealie-smtp` Secret).

## 6. Modified chart template: postgres-deployment.yaml

- [x] 6.1 Sidecar kept (gated on `observability.enabled`), with env vars unchanged.
- [x] 6.2 Container port `9187` named `metrics` already present from prior work.
- [x] 6.3 Service `mealie-postgres-exporter` with label `app.kubernetes.io/component: metrics-exporter` added in `service-monitors.yaml`. Pod-level annotations removed.
- [x] 6.4 Render verified: disabled = no sidecar / no metrics Service; enabled = sidecar + Service + ServiceMonitor present.

## 7. Prod values

- [x] 7.1 Added `observability:` block to `helm/values/prod.yaml` (enabled, cluster, grafana host, SMTP refs). Also added a top-level `kube-prometheus-stack.alertmanager.config` block with real Resend SMTP globals + receivers + email route to `andygjenkins@gmail.com`. Deliberately placed in prod.yaml (not values.yaml) because Alertmanager's `global.smtp_*` config is literal YAML the subchart consumes — this is the Helm-native way to pass prod-specific real values:
      ```yaml
      observability:
        enabled: true
        grafana:
          host: "grafana.jenkinz.net"
          existingSecret: "grafana-admin"
          storage: 2Gi
        prometheus:
          retention: "7d"
          storage: 10Gi
        alertmanager:
          storage: 1Gi
          smtpFromAddress: "alerts@mealie.jenkinz.net"
          smtpToAddress:   "andygjenkins@gmail.com"
          existingSmtpSecret: "mealie-smtp"
      ```
- [ ] 7.2 Confirm `helm/values/prod.yaml` contains no `adminPassword`, `SMTP_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, or similar literal-credential keys.

## 8. Justfile: grafana-admin-bootstrap recipe

- [x] 8.1 `just grafana-admin-bootstrap` recipe added, fail-fast on missing env vars, idempotent dry-run-apply.
- [x] 8.2 Confirmed `just --list` shows `grafana-admin-bootstrap`; retired Grafana Cloud version is gone.

## 9. Cloudflare DNS for grafana.jenkinz.net (user action, one-time)

- [ ] 9.1 Log into Cloudflare, zone `jenkinz.net` → **DNS → Records → Add record**. Type: `CNAME`. Name: `grafana`. Target: `mealie.jenkinz.net`. Proxy status: **DNS only** (grey cloud — keeps TLS simple since cert-manager does DNS-01 directly). TTL: Auto.
- [ ] 9.2 Verify: `dig +short grafana.jenkinz.net` — returns an A record matching the VPS IP (after CNAME resolution).

## 10. Documentation

- [x] 10.1 Rewrote `k8s/observability/README.md` for the self-hosted story. Sections:
      - **Architecture**: what each stack component does, data flow (Prometheus scrapes → stores; Alertmanager fires → Resend SMTP; Grafana renders).
      - **Why self-hosted** (summary of design.md decision 1; link to full design).
      - **One-time setup**:
          - Cloudflare DNS record for `grafana.jenkinz.net` (CNAME, grey cloud).
          - Uptime Robot signup + single HTTP check for `https://mealie.jenkinz.net/api/app/about` every 5 min, alerting to `andygjenkins@gmail.com`. Save login to 1Password as **Uptime Robot – account (mealie)**.
          - Generate Grafana admin credentials: `openssl rand -base64 24` for password. Save to 1Password as **Mealie – Grafana admin (prod)**.
      - **Deploy flow**:
          - `KUBECONFIG=~/.kube/mealie-prod.yaml kubectl apply -f k8s/observability/traefik-metrics.yaml` (if not done).
          - `export GRAFANA_ADMIN_USER=admin; export GRAFANA_ADMIN_PASSWORD="$(op read 'op://Personal/Mealie – Grafana admin (prod)/password')"`.
          - `just grafana-admin-bootstrap`.
          - Re-export `MEALIE_SECRET_KEY` + `POSTGRES_PASSWORD`; `just deploy-prod`.
      - **Verification**:
          - Pod list (expect ~10 new pods across mealie + kube-system for the operator).
          - `https://grafana.jenkinz.net` — log in, land on the home dashboard.
          - Open Explore → run `up{}` — expect >=10 series with value 1 (Prometheus self, node-exporter, kube-state-metrics, postgres-exporter, Traefik, cert-manager, operator, Alertmanager, Grafana).
          - Open Dashboards → Browse → find "Mealie Overview" (auto-imported via ConfigMap) — panels populate within 5 min.
          - Open Alerts → Alert rules — expect exactly 5 rules, all in state "inactive" on a healthy cluster.
      - **Editing alerts**:
          - Alerts live in `helm/mealie/templates/prometheus-rules.yaml`. Edit → PR → merge → `just deploy-prod`. Operator reconciles the CRD within ~10s. No restart needed.
      - **Adding dashboards**:
          - Either (a) copy a JSON into `helm/mealie/dashboards/` and add a template that wraps it in a ConfigMap with `grafana_dashboard: "1"`, or (b) use Grafana's UI to build + export, then follow (a).
      - **Rotating Grafana admin password**:
          - `openssl rand -base64 24` → save to 1Password → `export GRAFANA_ADMIN_PASSWORD=…` → `just grafana-admin-bootstrap` → `kubectl -n mealie rollout restart deployment/mealie-grafana`. Log in with the new password.
      - **Induce-each-alert test plan** (copy from 11.x below).
      - **Troubleshooting**: pods not Ready (OOM, PVC mount), Alertmanager not sending (SMTP creds wrong / secret key mismatch), PrometheusRule failing to load (syntax / missing metric), PVC filling too fast (retention drift / high-cardinality target).
- [x] 10.2 Updated root `README.md`:
      - Production Deploy quick-reference: swap the phase-8 line from Grafana Cloud to "self-hosted kube-prometheus-stack (see k8s/observability/README.md)".
      - First-time-deploy checklist step 8: replace Grafana Cloud bootstrap commands with `kubectl apply -f k8s/observability/traefik-metrics.yaml`, `just grafana-admin-bootstrap`, and a note to redeploy. Mention the new Cloudflare DNS record for `grafana.jenkinz.net` as a prerequisite.

## 11. Deploy + verify in prod (user actions)

- [ ] 11.1 Open a PR with all chart + template + values + justfile + docs changes. Review both renders (dev = unchanged; prod = adds the full observability stack). **[needs review]**
- [ ] 11.2 Merge. Check out main locally.
- [ ] 11.3 Cloudflare DNS record for `grafana.jenkinz.net` in place (task 9). **[user action]**
- [ ] 11.4 `kubectl apply -f k8s/observability/traefik-metrics.yaml` (if still not applied). **[user action]**
- [ ] 11.5 Generate Grafana admin password, save to 1Password, export env vars, `just grafana-admin-bootstrap`. Verify Secret exists with two keys. **[user action]**
- [ ] 11.6 Re-export `MEALIE_SECRET_KEY` + `POSTGRES_PASSWORD`; `just deploy-prod`. Watch rollout (`kubectl -n mealie get pods -w`). Expect Prometheus, Grafana, Alertmanager, node-exporter (kube-system), kube-state-metrics, prometheus-operator pods to come up. **[user action]**
- [ ] 11.7 Cert-manager issues `grafana-tls` within ~90s. Verify: `kubectl -n mealie get cert grafana-tls`. **[user action]**
- [ ] 11.8 `curl -sSI https://grafana.jenkinz.net/api/health | head -1` returns `HTTP/2 200`. **[user action]**
- [ ] 11.9 Log into Grafana. Open **Explore** → run `up{}` — ≥10 series with `up=1`. **[user action]**
- [ ] 11.10 Open **Dashboards** → find "Mealie Overview" → all panels populate within 5 min. **[user action]**
- [ ] 11.11 Open **Alerting → Alert rules** — all 5 alerts listed, all `Inactive`. **[user action]**

## 12. Induce each alert to verify end-to-end delivery

- [ ] 12.1 **MealieDeploymentNotReady**: `kubectl -n mealie scale deployment/mealie --replicas=0`; wait 6 min; email arrives; rescale to 1; resolved email arrives. **[user action]**
- [ ] 12.2 **NoRecentMealieBackup**: harder to induce; preview the rule in Grafana (Alerting → Alert rules → the rule → Preview) to confirm the query returns a number (time-since-last-completion) that *would* cross 26h if no backups ran. **[user action]**
- [ ] 12.3 **MealiePVCFilling**: `kubectl -n mealie exec deployment/mealie -- dd if=/dev/zero of=/app/data/fill.tmp bs=1M count=<enough-for->85%>`; wait 30 min; email arrives; `rm /app/data/fill.tmp`. **[user action]**
- [ ] 12.4 **MealieTLSExpiring**: cert is fresh; preview rule, confirm query returns expected days-until-expiry value >14. **[user action]**
- [ ] 12.5 **MealiePostgresDown**: `kubectl -n mealie scale statefulset/mealie-postgres --replicas=0`; wait 6 min; email arrives; rescale to 1; resolved. **[Mealie becomes unavailable during this — do in low-traffic window; user action]**
- [ ] 12.6 All 5 alerts observed firing and resolving. Runbook's 5-alert table updated if any PromQL needed tweaks.

## 13. Set up Uptime Robot (user action, one-time)

- [ ] 13.1 Sign up at https://uptimerobot.com (free tier, no card). Save login to 1Password as **Uptime Robot – account (mealie)**.
- [ ] 13.2 Create a new monitor: Type HTTP(s). Friendly name `mealie-prod`. URL `https://mealie.jenkinz.net/api/app/about`. Interval 5 min. Timeout 30s.
- [ ] 13.3 Add email alert contact: `andygjenkins@gmail.com`. Attach to the `mealie-prod` monitor.
- [ ] 13.4 Verify: see the monitor flip to `Up` in green within 5 min. Optional: briefly stop the Mealie Deployment (`kubectl -n mealie scale deployment/mealie --replicas=0`) for 10 min to confirm an alert email arrives from Uptime Robot; scale back up.

## 14. Archive

- [ ] 14.1 When all prior tasks are checked, run `/opsx:archive add-kube-prometheus-stack`.
- [ ] 14.2 Update the hosting-plan memory: phase 8 complete (all 8 phases done — this closes out the original plan). Flag any deferred items that might graduate to a new plan (add-loki, add-sso, automate-prod-deploy, etc.).
