# Observability (Phase 8)

Self-hosted metrics, dashboards, and alerts for the Mealie deployment on the
Hetzner CX33 K3s cluster. Shipped via the upstream `kube-prometheus-stack`
Helm chart as a subchart of `helm/mealie/`. Nothing leaves the VPS except
email (via the existing Resend SMTP setup) and one external reachability
probe from Uptime Robot.

> **Not Grafana Cloud.** An earlier attempt used Alloy → Grafana Cloud; it
> was abandoned after the "too much RAM to self-host" argument didn't survive
> sizing. See `openspec/changes/archive/…add-kube-prometheus-stack*/proposal.md`
> (once archived) or `design.md` Decision 1 for the full reasoning.

## What runs where

| Component | Namespace | Role |
|---|---|---|
| Prometheus (operator-managed) | `mealie` | TSDB + scrape engine, 7-day retention |
| Grafana | `mealie` | UI at `https://grafana.jenkinz.net` |
| Alertmanager | `mealie` | Alert routing, sends email via Resend SMTP |
| prometheus-operator | `mealie` | Reconciles ServiceMonitor / PrometheusRule CRDs |
| kube-state-metrics | `mealie` | Kubernetes API state as metrics |
| prometheus-node-exporter | `mealie` | Host-level node metrics (DaemonSet) |
| postgres-exporter sidecar | `mealie` | Mealie Postgres internals (pg_up, conns, DB size) |
| Traefik `/metrics` | `kube-system` | HTTP request / p95 / error rate (enabled via K3s HelmChartConfig) |
| cert-manager `/metrics` | `cert-manager` | TLS certificate expiry |
| Uptime Robot (external) | — | One HTTP check against `mealie.jenkinz.net` — covers VPS-down |

## One-time setup

### 1. Cloudflare DNS for `grafana.jenkinz.net`

Match the `mealie.jenkinz.net` pattern: A record to the VPS IP, proxied
through Cloudflare (orange cloud, Full-Strict TLS). DNS-01 cert issuance
works the same through the proxy — cert-manager adds TXT records via the
Cloudflare API, which aren't proxied regardless of the A record's status.

Get the VPS IP first:
```bash
hcloud server ip mealie-prod
```

Then Cloudflare → zone `jenkinz.net` → **DNS → Records → Add record**:

- Type: **A**
- Name: `grafana`
- IPv4 address: the VPS IP from above
- Proxy status: **Proxied** (orange cloud)
- TTL: Auto

Verify propagation (orange-cloud records resolve to Cloudflare proxy IPs,
not the origin — matching `dig +short mealie.jenkinz.net`):
```bash
dig +short grafana.jenkinz.net
```

### 2. Traefik metrics (one-time)

Apply the K3s `HelmChartConfig` that enables Traefik's `/metrics` endpoint
on port 9100:

```bash
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl apply -f k8s/observability/traefik-metrics.yaml
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n kube-system rollout status deployment/traefik
```

Confirm the site still works:
```bash
just smoke-url https://mealie.jenkinz.net
```

This override survives K3s upgrades — `HelmChartConfig` is the supported
mechanism for customizing K3s's bundled Traefik.

### 3. Generate Grafana admin credentials

```bash
openssl rand -base64 24
```

Save to 1Password as **Mealie – Grafana admin (prod)** with fields
`username: admin` and `password: <the generated value>`.

### 4. Bootstrap the `grafana-admin` Secret

```bash
export GRAFANA_ADMIN_USER="$(op read 'op://Personal/Mealie – Grafana admin (prod)/username')"
export GRAFANA_ADMIN_PASSWORD="$(op read 'op://Personal/Mealie – Grafana admin (prod)/password')"

just grafana-admin-bootstrap
```

Verify:
```bash
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie get secret grafana-admin -o jsonpath='{.data}' | jq 'keys'
# Expect: ["admin-password", "admin-user"]
```

### 5. Deploy

```bash
export MEALIE_SECRET_KEY="$(op read 'op://Personal/Mealie – SECRET_KEY (prod)/credential')"
export POSTGRES_PASSWORD="$(op read 'op://Personal/Mealie – Postgres password (prod)/credential')"

just deploy-prod
```

First deploy pulls the kube-prometheus-stack subchart (~50 MB) and brings up
~10 new pods. Watch rollout:

```bash
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie get pods -w
```

Expect to see (names may be abbreviated by the operator):

- `mealie-kube-prometheus-sta-operator-<hash>` (1 pod)
- `prometheus-mealie-kube-prometheus-sta-prometheus-0` (StatefulSet, 1 pod)
- `alertmanager-mealie-kube-prometheus-sta-alertmanager-0` (StatefulSet, 1 pod)
- `mealie-grafana-<hash>` (1 pod, 3 containers: grafana + sidecar + sc-dashboard)
- `mealie-kube-state-metrics-<hash>` (1 pod)
- `mealie-prometheus-node-exporter-<hash>` (DaemonSet, 1 pod per node)
- `mealie-postgres-0` now shows 2/2 Ready (the exporter sidecar joined)

Certificate for `grafana.jenkinz.net` is issued by cert-manager via DNS-01
within ~90 seconds:

```bash
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie get cert
```

### 6. Uptime Robot (external)

Covers the one class of failure that in-cluster monitoring physically
cannot: the VPS itself is down.

1. Sign up at https://uptimerobot.com (free tier; no card). Save login to
   1Password as **Uptime Robot – account (mealie)**.
2. Create monitor:
   - Type: **HTTP(s)**
   - Friendly name: `mealie-prod`
   - URL: `https://mealie.jenkinz.net/api/app/about`
   - Monitoring interval: 5 minutes
   - Monitoring timeout: 30 seconds
3. Add alert contact:
   - Type: **Email**
   - Address: `andygjenkins@gmail.com`
   - Attach to the `mealie-prod` monitor.
4. Verify the monitor flips to green within 5 minutes.

## Verifying the pipeline

Open `https://grafana.jenkinz.net` and log in as `admin` with the password
from step 3.

**Metrics sanity** — Explore (left nav) → Prometheus data source → run:

```promql
up{}
```

Expect ≥10 series with `up=1`:
- `prometheus` (scraping itself)
- `alertmanager`
- `grafana`
- `kube-state-metrics`
- `node-exporter`
- `kubelet`
- `cadvisor`
- `apiserver`
- `mealie-postgres-exporter` (from our ServiceMonitor)
- `traefik` (from our ServiceMonitor, once traefik-metrics.yaml is applied)

**Dashboards** — Dashboards (left nav) → Browse:

- **Mealie Overview** — our own, imported from the ConfigMap at deploy time.
  Panels should populate within ~2 minutes of first scrape.
- **Kubernetes / Compute Resources / Cluster**, **Node Exporter / Full**,
  **PostgreSQL** — bundled with kube-prometheus-stack.

**Alerts** — Alerting (left nav) → Alert rules:

Expect exactly 5 rules under the group `mealie-mealie-prod`:

- `MealieDeploymentNotReady`
- `NoRecentMealieBackup`
- `MealiePVCFilling`
- `MealieTLSExpiring`
- `MealiePostgresDown`

All should show state **Normal** on a healthy cluster.

## Editing alerts

Alerts live in `helm/mealie/templates/prometheus-rules.yaml` as a single
PrometheusRule CRD. To change a threshold, add, or remove an alert:

1. Edit the YAML.
2. Open a PR, review, merge.
3. `just deploy-prod`. The prometheus-operator reconciles the CRD within
   ~10 seconds — no Prometheus restart needed.
4. Confirm in the Grafana UI (Alerting → Alert rules) that the change took effect.

## Adding a dashboard

Grafana's sidecar watches for ConfigMaps labeled `grafana_dashboard=1` in
any namespace and auto-imports them.

1. Build the dashboard in the Grafana UI, then export JSON (**Dashboard settings → JSON Model → Copy**).
2. Save the JSON to `helm/mealie/dashboards/<name>.json`.
3. Add a ConfigMap template in `helm/mealie/templates/` similar to
   `grafana-dashboard-mealie.yaml`, wrapping the JSON via
   `{{ .Files.Get "dashboards/<name>.json" }}`.
4. `just deploy-prod`. The sidecar picks it up within ~30 seconds.

## Rotating the Grafana admin password

1. Generate new password: `openssl rand -base64 24`.
2. Update 1Password entry **Mealie – Grafana admin (prod)**.
3. Re-export env vars and re-run bootstrap:
   ```bash
   export GRAFANA_ADMIN_USER="$(op read 'op://Personal/Mealie – Grafana admin (prod)/username')"
   export GRAFANA_ADMIN_PASSWORD="$(op read 'op://Personal/Mealie – Grafana admin (prod)/password')"
   just grafana-admin-bootstrap
   ```
4. Restart Grafana so it re-reads the Secret:
   ```bash
   KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie rollout restart deployment mealie-grafana
   ```
5. Log in with the new password.

## Inducing each alert (test plan)

Untested alerts are decoration. Run once after first deploy. All alerts
route to `andygjenkins@gmail.com` via Resend.

### 1. MealieDeploymentNotReady (5m, critical)

```bash
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie scale deployment/mealie --replicas=0
# Wait 6 minutes. Email arrives from alerts@mealie.jenkinz.net.
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie scale deployment/mealie --replicas=1
# Within ~2 min, "[RESOLVED]" email arrives.
```

### 2. NoRecentMealieBackup (15m, high)

Hard to induce (26h wait). Instead, preview the rule:
Grafana → Alerting → Alert rules → `NoRecentMealieBackup` → **Preview**.
Confirm the query returns a number (seconds-since-last-completion) less
than `26 * 3600`, i.e. alert is correctly in state Normal.

### 3. MealiePVCFilling (30m, high)

```bash
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie exec deployment/mealie -- df -h /app/data
# Adjust count to >85% of the 5Gi PVC (roughly 4300 MiB):
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie exec deployment/mealie -- dd if=/dev/zero of=/app/data/fill.tmp bs=1M count=4300
# Wait 30 minutes. Email arrives.
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie exec deployment/mealie -- rm /app/data/fill.tmp
# Within ~2 min after deletion, [RESOLVED] email arrives.
```

### 4. MealieTLSExpiring (1h, medium)

Cert is fresh; preview the rule, confirm the query returns >14 days.
A real induce would require either waiting 76+ days, or manually editing
the Certificate's notAfter — not worth it.

### 5. MealiePostgresDown (5m, critical)

**Mealie becomes unavailable during this — do it in a low-traffic window.**

```bash
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie scale statefulset/mealie-postgres --replicas=0
# Wait 6 min. Email arrives.
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie scale statefulset/mealie-postgres --replicas=1
# [RESOLVED] email arrives once Postgres + sidecar come back.
```

## Silencing alerts during a planned deploy

Grafana → Alerting → **Silences → New silence**:

- Matchers: `alertname=~".+"` (silences all alerts)
- Or narrower: `alertname="MealieDeploymentNotReady"`
- Duration: `30m` (or however long the deploy takes)
- Comment: "deploy mealie v3.X — Andy"

Silences auto-expire.

## Troubleshooting

**Grafana pod stuck Pending.** Probably PVC provisioning: `kubectl -n mealie describe pod -l app.kubernetes.io/name=grafana`. On K3s with local-path-provisioner the PVC should bind immediately; if not, check the storageclass.

**`MealiePostgresDown` fires right after first deploy.** The postgres-exporter sidecar needs ~30s to connect after startup. If it's still firing after 2 minutes: `kubectl -n mealie logs mealie-postgres-0 -c postgres-exporter`. Usually a `DATA_SOURCE_USER/PASS` mismatch — the chart wires them from the same values as the main postgres container, so the envs should always match. Confirm with `kubectl -n mealie get pod mealie-postgres-0 -o yaml | grep -A2 DATA_SOURCE`.

**Alertmanager logs `smtp: failed to auth`.** The `mealie-smtp` Secret is either missing or has the wrong key names. Alertmanager expects exactly `SMTP_USER` and `SMTP_PASSWORD`. Check `kubectl -n mealie get secret mealie-smtp -o yaml` and re-run `just smtp-bootstrap` if needed.

**PrometheusRule fails to load.** `kubectl -n mealie get prometheusrule -o yaml | grep -A3 status`. Most often a typo in PromQL — check `kubectl -n mealie logs prometheus-mealie-kube-prometheus-sta-prometheus-0 -c prometheus | grep -i rule`.

**PVC filling too fast.** Prometheus's 10Gi PVC should last many months at our cardinality. If it fills within weeks, a noisy scrape target has been added. Check `prometheus_tsdb_head_series` and bring down the worst offender or drop labels via a `relabel_configs` on the offending ServiceMonitor.

**Dashboard doesn't auto-import.** The sidecar logs show what it picked up: `kubectl -n mealie logs mealie-grafana -c grafana-sc-dashboard`. Common issue: ConfigMap missing the `grafana_dashboard: "1"` label (string `"1"`, not int).

**Cert `grafana-tls` stuck.** `kubectl -n mealie describe cert grafana-tls`. cert-manager's DNS-01 solver uses the same Cloudflare token as `mealie-tls` (phase 4); if that works for mealie it should work for grafana. Wait ~2 min after Ingress creation.

## Rollback

Soft rollback (keep data, disable stack):
```bash
# In helm/values/prod.yaml, flip observability.enabled to false
just deploy-prod
```
PVCs for Prometheus / Grafana / Alertmanager are retained by the storageclass.

Hard rollback (free VPS disk):
```bash
KUBECONFIG=~/.kube/mealie-prod.yaml kubectl -n mealie delete pvc -l app.kubernetes.io/instance=mealie -l app.kubernetes.io/part-of=kube-prometheus-stack
```

## Resource footprint

At steady state on an idle cluster:

- Prometheus: ~300 Mi RSS (below the 800 Mi limit)
- Grafana: ~150 Mi
- Alertmanager: ~40 Mi
- operator: ~80 Mi
- node-exporter: ~20 Mi
- kube-state-metrics: ~50 Mi
- postgres-exporter sidecar: ~25 Mi

Total ≈ **670 Mi actual**, ~800 Mi reserved via requests, ~1.8 Gi headroom to
limits. Well inside the CX33's ~6 Gi free RAM budget.
