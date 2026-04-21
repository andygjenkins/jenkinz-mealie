# Project Context

## Purpose
Self-host Mealie, an open-source recipe manager, on a single-node Kubernetes cluster for
extended-family use — while using the build-out as practical K8s learning. The
deployment emphasizes reliability, low cost (~€7/mo), and transferable patterns
(real K3s + Helm + cert-manager, not Docker Compose).

**Target URL**: https://mealie.jenkinz.net

## Tech Stack

### Infrastructure
- **VPS**: Hetzner **CX33** (4 vCPU Intel, 8 GB RAM, 80 GB SSD) — €6.49/mo + €0.50/mo IPv4 (DE/FI region, post-April-2026 pricing)
- **OS**: Ubuntu 24.04 LTS
- **Kubernetes**: K3s (single-node, lightweight)
- **Firewall**: UFW (allow 22/80/443 only)

### Kubernetes Components
- **Ingress**: Traefik (K3s built-in, no extra install)
- **TLS**: cert-manager + Let's Encrypt (DNS-01 via Cloudflare)
- **Secrets**: `kubectl create secret` seeded from 1Password at launch. Sealed-secrets is a later learning milestone, not a launch requirement.
- **GitOps**: None at launch. `helm upgrade --install` from a GitHub Actions workflow on push to `main`. ArgoCD/Flux is a deferred learning milestone.
- **Package Manager**: Helm 3.x

### Application Stack
- **Application**: Mealie (recipe management; pre-seeded with 5 family households: `JenkinsJnrs`, `JenkinsSnrs`, `Munchkins`, `Frenkins`, `Hongkins`)
- **Database**: PostgreSQL 15 in-cluster (StatefulSet, PVC-backed)
- **Email**: Gmail SMTP (notifications, password resets)

### Observability
- **Approach**: **Grafana Cloud Free Tier** — Grafana Alloy agent scrapes the cluster (~150 MB RAM) and ships metrics/logs to Grafana-hosted backends.
- **Why not in-cluster Prometheus**: kube-prometheus-stack alone would claim ~1.5 GB RAM on an 8-GB VPS, pre-committing ~18% of capacity to observability and squeezing headroom for future apps. Grafana Cloud gives the same learning value (PromQL, ServiceMonitors) and dashboards without that tax.

### Development
- **Local Cluster**: **k3d** (K3s in Docker) — parity with prod orchestrator
- **Dev Workflow**: Tilt (hot-reload, port-forward at localhost:9000)

### Backup
- **Jobs**: Kubernetes CronJob — `pg_dump | gzip | restic backup --stdin` daily
- **Offsite Storage**: Backblaze B2
- **Acceptance criterion for the backup phase**: tested `just restore-drill` command, not the CronJob itself

## Project Conventions

### Code Style
- Kubernetes manifests use YAML with 2-space indentation
- Helm values files follow upstream chart conventions
- Shell scripts use bash with `set -euo pipefail`

### Architecture Patterns
- **Local-first development**: Build and validate in k3d+Tilt before VPS deployment
- **Single prod environment on the VPS**: no ref/staging namespace at launch; local k3d is dev, VPS is prod
- **Multi-tenancy via K3s namespaces** for future apps: Mealie now, plus potential `vaultwarden`, `immich`, `nextcloud`, `grafana-agent` etc., each isolated in its own namespace but sharing Traefik + cert-manager

### Testing Strategy
- Each task must include automated test, script, or justfile recipe demonstrating the change
- Deployment-gate smoke test (`scripts/smoke-test.sh`) runs against any URL (local or prod); reused as acceptance gate in every phase
- Backup/restore procedures must be tested end-to-end

### Git Workflow
- Ephemeral branches for feature work
- Local merge to main
- Track non-trivial work as OpenSpec changes under `openspec/changes/`
- Commit messages describe what changed and why

## Domain Context
- **Mealie**: Self-hosted recipe manager. Group → Households tenancy model: one group (`Jenkinz`) owns the recipe library; households (`JenkinsJnrs`, etc.) each have their own meal plans and shopping lists.
- **K3s**: Lightweight Kubernetes for edge/home-lab use; single-binary, bundles Traefik + ServiceLB + local-path-provisioner.
- **Traefik**: Cloud-native ingress controller, K3s default.
- **Grafana Alloy**: Grafana's scrape-and-ship agent; replaces a local Prometheus when using Grafana Cloud.

## Important Constraints
- **Budget**: ~€7/month (Hetzner CX33 + IPv4). Backblaze B2 backups are $0.006/GB-month + egress (pennies for Mealie data).
- **Availability**: 99%+ (best-effort for self-hosted single-node)
- **Single node**: No HA/multi-node cluster (out of scope)
- **No custom Mealie modifications**: Use upstream Docker image only
- **Architecture lock-in**: Hetzner can't live-migrate across arch lines (Intel CX ↔ ARM CAX requires reinstall). Pick upfront: **Intel (CX)** is chosen.

## Capacity Planning (CX33 8 GB RAM)

Rough steady-state per app:

| Component | RAM |
|---|---|
| K3s + Traefik + kubelet + CoreDNS | ~500 MB |
| cert-manager | ~100 MB |
| Mealie + PostgreSQL | ~700 MB |
| Grafana Alloy agent | ~150 MB |
| **Launch footprint** | **~1.5 GB** |

Leaves **~6 GB headroom** for future self-hosted apps (Vaultwarden ~150 MB, Immich ~1.5 GB, Nextcloud ~800 MB, etc.). When the node fills up, **upgrade to Hetzner CX43** (16 GB RAM, €11.99/mo) — a 1–2 minute in-place resize from the Hetzner console.

## External Dependencies
- **Hetzner Cloud**: VPS hosting
- **Porkbun**: Domain registrar for `jenkinz.net` (registration + WHOIS only; not authoritative for DNS)
- **Cloudflare**: Authoritative DNS for `jenkinz.net`, HTTP(S) proxy + WAF, DNS-01 ACME solver for cert-manager
- **Tailscale**: Private mesh for ops-plane access (kubectl via tailnet; free plan ≤100 devices)
- **Let's Encrypt**: Free TLS certificates (issued via Cloudflare DNS-01)
- **Backblaze B2**: S3-compatible offsite backup storage
- **Gmail SMTP**: Email delivery for notifications
- **Grafana Cloud**: Metrics, logs, dashboards (free tier)
- **1Password**: Source of truth for secrets at launch (manual `kubectl create secret` workflow)

## Repository Structure
```
.
├── README.md / LOCAL_DEV.md / AGENTS.md / CLAUDE.md
├── openspec/
│   ├── project.md          # This file
│   ├── specs/              # Current truth — what IS built
│   │   ├── local-dev/
│   │   └── smoke-tests/
│   └── changes/            # Proposals + archived changes
├── helm/
│   ├── mealie/             # Mealie Helm chart
│   └── values/
│       ├── dev.yaml        # k3d/Tilt overrides
│       └── prod.yaml       # (phase 5) VPS overrides
├── scripts/                # seed.sh, smoke-test.sh, (future) backup/restore
├── Tiltfile                # Local dev
└── justfile                # Task runner recipes
```

## Implementation Phases (approved plan — see `/Users/aj/.claude/plans/great-can-we-joyful-forest.md`)

| # | Change | Status |
|---|---|---|
| 1 | `add-deployment-smoke-tests` | ✅ Archived 2026-04-20 |
| 2 | `switch-local-dev-to-k3d` | ✅ Archived 2026-04-20 |
| 3 | `provision-hetzner-k3s` | ⏳ Next — cloud-init + K3s on CX33 |
| 4 | `add-dns-and-tls` | ⏳ cert-manager + Let's Encrypt DNS-01 |
| 5 | `deploy-mealie-prod` | ⏳ prod.yaml + GitHub Actions deploy workflow |
| 6 | `add-prod-backups` | ⏳ pg_dump + restic → B2, with tested restore drill |
| 7 | `add-email-smtp` | ⏳ Gmail SMTP for invites/password resets |
| 8 | `add-grafana-cloud-agent` | ⏳ Grafana Alloy scraping → Grafana Cloud free tier |

**Deferred learning milestones** (future, not in approved plan): `add-sealed-secrets`,
`add-gitops-argocd`, `add-renovate`.
