# Design: Self-Hosted Monitoring via kube-prometheus-stack

## Context

Current state: Mealie live at `mealie.jenkinz.net` with TLS, daily B2 backups,
Resend SMTP. Zero observability — and phase 8's first attempt (Grafana Cloud
via Alloy) was abandoned partway through implementation. The abandoned
change dropped about a day of chart work into the repo (Alloy DaemonSet +
subchart wiring, kube-state-metrics as a sibling subchart, postgres-exporter
sidecar, Alloy config ConfigMap). Some of that survives this change; some
gets deleted.

Constraints:

- **Single-node K3s on Hetzner CX33**: 4 vCPU, 8 GB RAM, 80 GB disk. After
  Mealie + Postgres + K3s system pods + cert-manager + backup CronJob, about
  **6 GB of RAM and ~70 GB of disk** are free. This is the budget for the
  monitoring stack.
- **Manual Secret bootstrap from 1Password**. Consistent with every prior
  phase. No sealed-secrets, no External Secrets Operator.
- **`helm upgrade --install` from the laptop**. No GitOps, no ArgoCD.
- **SMTP already lives in the cluster** (phase 7 Resend). Alertmanager's
  email delivery reuses it — one credential to rotate, not two.
- **Ingress story already works** (phase 4 Traefik + cert-manager +
  Cloudflare DNS-01). Adding a Grafana subdomain is ~5 lines of config, not
  a new architecture.

Stakeholder: Andy, solo operator. Goals: observe the family deployment + learn
the K8s observability stack hands-on. Hannah is a potential future read-only
Grafana user but not a requirement today.

## Goals / Non-Goals

**Goals:**

- Catch the five most-likely family-Mealie failure modes: backup silently
  failing, PVC filling, TLS expiring, Mealie pod not Ready, Postgres
  unavailable.
- Hosted dashboards (Mealie overview + upstream-provided K8s + PostgreSQL)
  rendering at `grafana.jenkinz.net`.
- Alerts fire and deliver to Andy's inbox via the existing Resend setup.
- Everything runs on the existing CX33 within ~1 Gi RAM budget; no
  third-party SaaS dependency.
- Cover the "whole VPS is down" blind spot via an external uptime monitor.
- Learn the stack: PromQL, Alertmanager config, Grafana provisioning,
  ServiceMonitor + PrometheusRule CRDs.
- Reversible: if self-hosting stops working, rollback is `observability.enabled:
  false` and a deploy.

**Non-Goals:**

- Log aggregation (Loki) — separate future change.
- Tracing (Tempo).
- High availability (Prometheus, Alertmanager).
- Long-term metrics retention beyond 7 days.
- Multi-user / SSO Grafana.
- Synthetic probing *inside* the cluster (Uptime Robot external covers the
  critical case).
- Automated alert-as-code tooling beyond the native PrometheusRule CRD.

## Decisions

### Decision 1: Self-host over Grafana Cloud

**Chosen: self-host the full stack in-cluster.**

Reconsidered 2026-04-21 mid-apply of `add-grafana-cloud-agent`. The original
decision (go hosted) rested on a RAM estimate that didn't survive sizing.

- Actual footprint of a **tuned family-scale kube-prometheus-stack install**:
  Prometheus (400 Mi req / 800 Mi lim, 7-day retention) + Grafana (256 Mi /
  512 Mi) + Alertmanager (64 Mi / 128 Mi) + node-exporter (30 Mi) + kube-state-metrics
  (50 Mi) + prometheus-operator (100 Mi) ≈ **~900 Mi steady-state**.
- CX33 free after everything else: ~6 GB. Headroom ratio: ~6.7x the stack
  footprint.
- If we outgrow the CX33, the hosting plan already covers resize to CX43
  (16 GB) as a 1-2 min in-place operation. The monitoring stack is not
  what blocks scale.

With RAM no longer a blocker, the deciding factors are:

- **Learning value.** Running the stack teaches the observability stack.
  Configuring Alloy's remote_write URLs teaches Alloy's remote_write URL
  format. Andy's stated primary goal (from the hosting-plan memory) is
  hands-on K8s learning.
- **Dependency minimalism.** One fewer SaaS account to manage, monitor,
  and rotate. Grafana Cloud already proved it would reshuffle its UI on
  us mid-implementation — a small but real source of friction.
- **Data locality.** Metrics and logs stay on infrastructure we control.
  At our scale this is aesthetic rather than regulatory, but it's still
  the right default.

### Decision 2: Use the upstream `kube-prometheus-stack` chart, not hand-rolled

**Chosen: `prometheus-community/kube-prometheus-stack` as a single
conditional subchart.**

Alternatives considered:

- **Hand-rolled Prometheus + Grafana + Alertmanager Deployments.** Rejected:
  we'd maintain RBAC, PVCs, operator-equivalent reconciliation ourselves.
  Not useful learning at family scale — the real-world skill is knowing
  how to operate kube-prometheus-stack, which is what ~every K8s shop uses.
- **VictoriaMetrics single binary + Grafana + vmalert.** Rejected: smaller
  community, fewer pre-built dashboards, Andy would be learning a
  non-standard stack. Revisit if scale ever gets silly (not on our
  roadmap).
- **Alloy (collector) + self-hosted Mimir (storage) + self-hosted Loki +
  Grafana.** Rejected: splits collection from storage unnecessarily at this
  scale, and we'd still be configuring most of what Prometheus does natively.
  Over-architected.

kube-prometheus-stack bundles Prometheus, Grafana, Alertmanager, node-exporter,
kube-state-metrics, and the prometheus-operator. One subchart, one Helm dep,
one upgrade path.

We become a thin wrapper that ships:

- The operator-native resources (ServiceMonitor, PrometheusRule) describing
  *our* targets and *our* alerts.
- A ConfigMap wrapping `mealie-overview.json` (the sidecar auto-imports it).
- An Ingress for `grafana.jenkinz.net`.
- Values that tune retention, resources, storage, admin auth, Alertmanager
  email.

### Decision 3: Retention + storage sizing

- **Prometheus: 7-day retention, 10 Gi PVC.** Actual usage will be
  ~200 MB/day (small cluster, few targets), so ~1.5 GB at steady state.
  10 Gi is ~5× overhead for safety and to survive retention-policy drift.
- **Alertmanager: default 120h retention, 1 Gi PVC.** Alertmanager's disk
  use is dominated by the internal state file, which is tiny.
- **Grafana: 2 Gi PVC.** Grafana's sqlite DB + plugin cache + session state
  fits in well under 1 Gi; 2 Gi gives margin for plugin installs.
- **Storage class: K3s local-path** (same as Mealie's PVC). Not replicated,
  but neither is the database — and restic/B2 backups cover the database.
  We don't back up Prometheus TSDB; 7-day retention means losing the PVC
  means losing 7 days of metrics, which is acceptable (it's diagnostics,
  not business data).

Spec'd as hard limits: total across all observability PVCs ≤ 15 Gi
(10 + 2 + 1 + 2 headroom).

### Decision 4: Alertmanager → Resend SMTP, reusing phase 7 Secret

**Chosen: Alertmanager reads `SMTP_USER` and `SMTP_PASSWORD` from the
existing `mealie-smtp` Secret via envFrom / referenced secret in its config.**

Rationale:

- One credential to rotate when the Resend key rotates, not two.
- Tested SMTP path (we know phase 7 works end-to-end — Hannah got her
  invite email).
- Same From address domain (`mealie.jenkinz.net`) keeps DMARC/SPF simple.

**From address decision**: `alerts@mealie.jenkinz.net`. Separate local-part
from Mealie's own `no-reply@…` so inbox rules / filters can distinguish
"this is a machine alert" from "this is a household invitation." No new
DNS required — any local-part on an authenticated domain is valid.

**To address**: `andygjenkins@gmail.com`. Single recipient for now. Easy
to add a second (e.g. Hannah) by editing the Alertmanager config + redeploy;
documented in the runbook.

### Decision 5: Grafana at `grafana.jenkinz.net` with admin-Secret bootstrap

**Chosen:**

- New Ingress `grafana.jenkinz.net` on the existing Traefik + cert-manager
  stack. New Cloudflare DNS record: **A record to the VPS IP, orange cloud
  (proxied)** — mirrors the `mealie.jenkinz.net` setup exactly, so we keep
  WAF / DDoS / hidden-origin benefits consistently. cert-manager DNS-01 works
  identically through the proxy (challenge TXT records aren't proxied).
  Full-Strict TLS at Cloudflare re-validates our Let's Encrypt origin cert.
- Admin user + password in a Secret named `grafana-admin`, created by
  `just grafana-admin-bootstrap` from env vars `GRAFANA_ADMIN_USER` /
  `GRAFANA_ADMIN_PASSWORD`. Saved to 1Password, rotated manually.
- **Anonymous viewing disabled**. This is Andy's internal tool, not a
  public dashboard. Family members don't need to see Prometheus metrics.

Alternatives considered:

- **Port-forward only, no Ingress.** Rejected: painful, and part of the
  point is to get comfortable with operating Grafana.
- **Tailscale-only access.** Works but adds a "you can only view alerts
  on devices with Tailscale" friction. DNS-01 cert + Cloudflare Access
  (future) or just "admin password in 1Password" is simpler.
- **Cloudflare Access (Zero Trust) in front of Grafana.** Nice-to-have,
  but Grafana's own login is adequate for a solo user. Revisit if we add
  a second app that also needs auth and SSO pays off.

### Decision 6: Alerts as code (PrometheusRule CRD)

**Chosen: the five alerts live in `helm/mealie/templates/prometheus-rules.yaml`
as a PrometheusRule custom resource.** The prometheus-operator auto-loads
any PrometheusRule matching its selector (we set
`ruleSelectorNilUsesHelmValues: false` so it watches all namespaces / all
rules).

This is a **reversal** from the abandoned Grafana Cloud design, which
explicitly chose UI-managed alerts. The reason to reverse:

- In Grafana Cloud, the UI was the authoritative config surface — alert-as-code
  would have required Grizzly or Mimirtool, extra tooling for 5 alerts.
- With the operator, the CRD **is** the native authoritative form. A
  PrometheusRule YAML is how everyone in the K8s world does it. No extra
  tooling, just `kubectl apply` (via helm). Version control + PR review
  comes free.

The five alerts:

1. **MealieDeploymentNotReady** — `kube_deployment_status_replicas_ready{namespace="mealie",deployment="mealie"} < 1`, for 5m, severity `critical`.
2. **NoRecentMealieBackup** — `time() - max(kube_job_status_completion_time{namespace="mealie",job_name=~"mealie-backup.*"}) > 26*3600`, for 15m, severity `high`.
3. **MealiePVCFilling** — `kubelet_volume_stats_used_bytes{namespace="mealie"} / kubelet_volume_stats_capacity_bytes > 0.85`, for 30m, severity `high`.
4. **MealieTLSExpiring** — `(certmanager_certificate_expiration_timestamp_seconds{name="mealie-tls"} - time()) / 86400 < 14`, for 1h, severity `medium`.
5. **MealiePostgresDown** — `pg_up{namespace="mealie"} == 0`, for 5m, severity `critical`. (Via postgres-exporter. Replaces the "blackbox probe" alert from the hosted design, since that was Grafana-Cloud-synthetic-specific; external reachability is now Uptime Robot's job, not Alertmanager's.)

### Decision 7: ServiceMonitor-based scrape config (not annotation-based)

**Chosen: one ServiceMonitor per scrape target.** The prometheus-operator
watches ServiceMonitor CRs and programs Prometheus accordingly. We ship:

- `ServiceMonitor mealie-postgres` — selects the
  `app.kubernetes.io/component: metrics-exporter` label on the new Service
  fronting the postgres-exporter sidecar. Scrapes `:9187/metrics`.
- `ServiceMonitor traefik` — selects Traefik's Service in `kube-system`
  (label set by K3s's bundled chart). Scrapes `:9100/metrics` (the port
  enabled by `traefik-metrics.yaml` from the earlier phase 8 work).
- cert-manager usually ships its own ServiceMonitor when its chart is
  installed with `prometheus.enabled=true`. We check what the production
  cert-manager install already has; if not present, we add our own.

The `prometheus.io/scrape` pod annotations from the abandoned Alloy design
get removed from `postgres-deployment.yaml` — they're irrelevant to the
operator-based discovery path. Cleaner.

### Decision 8: Dashboards via sidecar ConfigMaps

**Chosen: kube-prometheus-stack's Grafana deployment already includes the
sidecar that watches for ConfigMaps labeled `grafana_dashboard=1` and
auto-imports them.**

Our chart ships one such ConfigMap wrapping `mealie-overview.json`
(unchanged from the abandoned change — a generic Grafana dashboard works
against any Prometheus, self-hosted or SaaS).

Upstream dashboards (Kubernetes / Compute Resources, Kubernetes / Networking,
PostgreSQL, node-exporter Full, prometheus) come bundled with
kube-prometheus-stack's Grafana defaults — we get them for free without
version-controlling the JSON. If we customize one of those, we'd copy its
JSON into our chart; deferred until we actually need to.

### Decision 9: Uptime Robot for the self-monitoring blind spot

**Chosen: single Uptime Robot free-tier HTTP check, documented as a 5-minute
out-of-band setup.**

Target: `https://mealie.jenkinz.net/api/app/about`. Frequency: 5 minutes
(the free-tier limit). Alert destination: email to
`andygjenkins@gmail.com`.

This covers the one class of failure in-cluster monitoring physically
cannot catch: **the VPS itself is down**. If the host is offline,
Prometheus can't scrape it and Alertmanager can't fire; but Uptime Robot
hits from the public internet and doesn't care what's happening inside.

Why not self-host uptime checking too? We'd need to run it on a second,
independent host — defeats the point. Keep this one external dependency.

Alternatives considered:

- **Better Uptime / BetterStack.** Paid beyond minimal usage. Overkill.
- **GitHub Actions cron hitting the URL.** Fragile (Actions scheduled
  runs can be delayed by 30+ min), and alerting via Actions is ugly.
- **Cloudflare Health Checks.** Decent, but paid beyond 1 check on the
  Free plan if tightly scoped; Uptime Robot's free tier is more generous.

### Decision 10: Resource budget is a hard spec requirement

Stack-wide: request ≤ 1 Gi RAM / 500 m CPU; limits ≤ 2 Gi RAM / 2 CPU.
Single scrape target breakdown (above in Decision 3) totals to ~900 Mi /
290 m requests. Spec'd explicitly so regressions during upgrades get caught
at PR time via `helm template | grep resources`.

If a future Mealie or Postgres upgrade tightens the actual free RAM, the
first lever is dropping Prometheus retention to 3 days (Alertmanager keeps
firing, we just lose query history). Second lever is dropping node-exporter's
fine-grained collectors. Third lever is CX43 upgrade.

## Risks / Trade-offs

- **[Risk] VPS is down → Prometheus is down → no alert from the cluster.**
  → Mitigation: Uptime Robot external check. Documented in runbook.
- **[Risk] Alertmanager can't send email (Resend outage, SMTP misconfig).**
  → Mitigation: Uptime Robot is independent and alerts via its own email
  path. If Resend is down we'd miss in-cluster alerts but still get the
  external one. Acceptable.
- **[Risk] Prometheus OOMs under unexpected cardinality (e.g. a noisy
  new target gets added).** → Mitigation: request/limit caps set in spec;
  PrometheusRule for `prometheus_tsdb_head_series > 500000` could be added
  later as a self-alert. For v1, we operate with defaults and tune if it
  happens.
- **[Risk] Grafana admin password compromised** (browser autofill leak,
  phished, etc.). → Mitigation: password in 1Password, rotate via
  `grafana-admin-bootstrap` + `kubectl rollout restart deployment/grafana`.
  Blast radius is limited — Grafana is read-only over metrics, can't touch
  the cluster.
- **[Risk] PrometheusRule YAML regresses and fails to load.** → Mitigation:
  prometheus-operator surfaces `PrometheusRuleFailures` metric; Prometheus
  itself logs on reload. Apply-time: `helm template` catches YAML-level
  errors; the operator catches CRD-level validation at apply time. Runtime:
  the operator keeps the last-good rule loaded, so a bad rule is a no-op,
  not an outage.
- **[Risk] PVC fills up (Prometheus TSDB).** → Mitigation: 10 Gi is 5× the
  expected usage; retention-policy-triggered deletion prevents unbounded
  growth. The existing "MealiePVCFilling" alert covers *all* PVCs in the
  mealie namespace, including Prometheus's — self-monitoring with
  grace.
- **[Risk] kube-prometheus-stack upgrades break compatibility.** → Mitigation:
  pin a stable version in `Chart.yaml`, read the release notes before
  bumping, test in k3d first (local-dev workflow from phase 2). Document
  the upgrade procedure in the runbook.
- **[Trade-off] Single-replica Prometheus = downtime during Prometheus
  restarts (pod restart, Helm upgrade) loses ~1 min of scraping.**
  Acceptable at family scale; dashboards show a small gap, nothing worse.
- **[Trade-off] No log aggregation ≠ no logs.** `kubectl logs` still works;
  we just don't have a UI to search-across-time. Add Loki in a follow-up
  change when it becomes painful.
- **[Trade-off] Grafana admin is solo.** If Andy is unavailable and Hannah
  needs to silence an alert, she'd need the admin password. Fine — shared
  1Password vault. Document as a Known Limitation.

## Migration Plan

This is a new capability *and* a rollback-plus-replacement of an
abandoned-mid-implementation change. Order matters.

**Step 0: clean up abandoned code.** Before applying this change, the
workspace contains partial Alloy wiring from `add-grafana-cloud-agent`.
Task 1.1 of this change explicitly removes it:

- Delete `helm/mealie/templates/alloy-config.yaml`.
- Remove the two subchart deps from `Chart.yaml` (`grafana/alloy`,
  `prometheus-community/kube-state-metrics`).
- `rm -rf helm/mealie/charts/alloy-*.tgz helm/mealie/charts/kube-state-metrics-*.tgz`.
- Rewrite `helm/mealie/values.yaml` observability block.
- Remove the `grafana-bootstrap` justfile recipe.
- Remove the Grafana Cloud-specific Uptime Robot-less runbook section.
- Delete `openspec/changes/add-grafana-cloud-agent/` directory.

This leaves the repo in a clean state: postgres-exporter sidecar still in
`postgres-deployment.yaml` (needed), `k8s/observability/traefik-metrics.yaml`
still present (needed), `mealie-overview.json` still present (needed).

**Step 1-4: build the new chart wiring.** Add the kube-prometheus-stack
subchart dep, `helm dep update`, write the new values block and the four
new templates.

**Step 5-6: prepare prod.** Pick `grafana.jenkinz.net` DNS target
(same IP as mealie.jenkinz.net), add CNAME at Cloudflare (DNS-only, grey
cloud — cert-manager uses DNS-01 so Cloudflare proxying would be fine, but
keeping it DNS-only is simpler and avoids double-TLS-termination).
Bootstrap `grafana-admin` Secret via `just grafana-admin-bootstrap`.

**Step 7: deploy.** `just deploy-prod`. Prometheus, Grafana, Alertmanager,
node-exporter, kube-state-metrics, operator all come up. ServiceMonitors
are discovered, PrometheusRule loaded, dashboard auto-imported.

**Step 8: verify.** Open `https://grafana.jenkinz.net`, log in with admin
credentials, confirm dashboards populate, confirm alerts in "inactive"
state (nothing wrong), confirm PromQL Explore works.

**Step 9: induce alerts to verify end-to-end delivery.** Same induce-and-heal
procedure as the abandoned change's test plan, but delivery path is now
Alertmanager → Resend → inbox instead of Grafana Cloud → SMTP.

**Step 10: set up Uptime Robot.** 5-min out-of-band task.

**Rollback strategy:**

- **Soft rollback (disable)**: flip `observability.enabled: false` in
  `helm/values/prod.yaml`, `just deploy-prod`. All in-cluster components
  are removed cleanly. PVCs persist (retain policy on StorageClass) so
  re-enabling recovers historical data.
- **Hard rollback (remove PVCs too)**: after disable,
  `kubectl -n mealie delete pvc -l app.kubernetes.io/part-of=kube-prometheus-stack`.
  Frees ~13 Gi on the VPS.
- **Full revert (undo this change entirely)**: revert the PR. Chart goes back
  to pre-phase-8 state. We'd still keep `postgres-exporter` sidecar
  disabled-by-default (`observability.enabled: false` hides it), so no
  cleanup needed there.

## Open Questions

All resolved by this design:

- **Self-host or SaaS?** Self-host — RAM no longer a blocker, learning wins.
- **Chart choice?** kube-prometheus-stack upstream.
- **Log aggregation included?** No — follow-up change.
- **Alerts in UI or as code?** As code (PrometheusRule CRDs — with the
  operator, this is the natural pattern, reversing the SaaS design's
  choice).
- **Grafana auth model?** Local admin in Secret, bootstrapped from
  1Password. Anonymous disabled. SSO deferred.
- **Grafana subdomain?** `grafana.jenkinz.net`. DNS at Cloudflare as CNAME
  to the Mealie record (same IP, same Traefik).
- **How to cover cluster-is-dead blind spot?** Uptime Robot free tier,
  external, documented in runbook.
- **Alertmanager email transport?** Existing Resend SMTP from phase 7;
  `mealie-smtp` Secret consumed directly — no duplication.
- **What happens to the abandoned change?** Its directory is deleted as
  part of step 0 of this change. The pivot story lives in this change's
  proposal.md and the updated hosting-plan memory; no dangling archive
  entry.
