# Mealie Kubernetes Deployment

Self-hosted [Mealie](https://mealie.io) recipe management application on Kubernetes.

## Overview

This repository contains Kubernetes manifests and Helm charts for deploying Mealie with PostgreSQL to a Kubernetes cluster. Designed for local development on k3d (K3s in Docker) and production deployment on K3s (Hetzner).

## Features

- 🍳 **Mealie** - Recipe management with web scraping, meal planning
- 🐘 **PostgreSQL 15** - Reliable database backend
- ⎈ **Helm Charts** - Templated, reusable Kubernetes manifests
- 🔄 **Tilt** - Hot-reload local development
- 🌐 **Ingress** - Traefik (K3s built-in) with TLS via cert-manager (production)

## Quick Start (Local Development)

### Prerequisites

- [Docker](https://www.docker.com/) (Docker Desktop or OrbStack)
- [k3d](https://k3d.io/) — `brew install k3d`
- [Tilt](https://tilt.dev/) — `brew install tilt-dev/tap/tilt`
- [Helm](https://helm.sh/docs/intro/install/) 3.x+
- [just](https://github.com/casey/just) — `brew install just`
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

### Deploy

```bash
just up    # creates the k3d cluster "mealie-dev" (first run) and launches Tilt
just seed  # seeds admin@test.com / testtest + a welcome recipe
just open  # opens http://localhost:9000
```

See [LOCAL_DEV.md](LOCAL_DEV.md) for detailed development instructions.

## Project Structure

```
.
├── helm/
│   ├── mealie/           # Main Helm chart
│   └── values/
│       ├── dev.yaml      # Local dev (k3d) overrides
│       └── prod.yaml     # Production overrides (phase 5)
├── infra/                # VPS provisioning (cloud-init + hcloud CLI)
│   ├── cloud-init.yaml
│   └── README.md         # Rebuild-from-scratch runbook
├── openspec/             # Spec-driven change proposals + truth
├── scripts/              # seed.sh, smoke-test.sh
├── Tiltfile              # Local dev with Tilt
├── LOCAL_DEV.md          # Local development guide
├── justfile              # Task recipes (local + vps-*)
└── README.md
```

## Production Deployment

Production runs on a single Hetzner Cloud CX33 VPS (Intel, 4 vCPU / 8 GB) with K3s.
The full rebuild-from-scratch runbook lives at [`infra/README.md`](infra/README.md).

Quick reference:

```bash
# Infrastructure (phase 3 — Hetzner + K3s + Tailscale)
just vps-create        # provision Hetzner VPS + install K3s via cloud-init
just vps-kubeconfig    # fetch kubeconfig to ~/.kube/mealie-prod.yaml
just vps-ssh           # SSH into the VPS as the admin user
just vps-destroy       # tear down (requires typed DESTROY confirmation)

# TLS (phase 4 — cert-manager + Let's Encrypt via Cloudflare DNS-01)
just tls-bootstrap     # install cert-manager + ClusterIssuers
just tls-test          # prove DNS-01 issuance works (self-cleaning staging cert)

# Mealie deploy (phase 5 — helm upgrade --install)
just deploy-prod                              # deploy/upgrade Mealie
just smoke-url https://mealie.jenkinz.net     # post-deploy health check

# Backups (phase 6 — pg_dump + restic → Backblaze B2, see k8s/backups/README.md)
just backup-bootstrap                         # one-time: seed backup-credentials Secret
just backup-now                               # ad-hoc backup on demand
just restore-drill                            # verify end-to-end restore

# SMTP (phase 7 — Resend → no-reply@mealie.jenkinz.net, see k8s/smtp/README.md)
just smtp-bootstrap                           # one-time: seed mealie-smtp Secret

# Observability (phase 8 — kube-prometheus-stack → grafana.jenkinz.net, see k8s/observability/README.md)
kubectl apply -f k8s/observability/traefik-metrics.yaml   # one-time: enable Traefik /metrics
just grafana-admin-bootstrap                  # one-time: seed grafana-admin Secret
```

### First-time production deploy

One-time, before the first `just deploy-prod`:

1. **Generate and save secrets** to 1Password:
   ```bash
   openssl rand -hex 32      # → "Mealie – SECRET_KEY (prod)"
   openssl rand -base64 24   # → "Mealie – Postgres password (prod)"
   ```
2. **Export into the shell**:
   ```bash
   export MEALIE_SECRET_KEY="$(op read 'op://Personal/Mealie – SECRET_KEY (prod)/credential')"
   export POSTGRES_PASSWORD="$(op read 'op://Personal/Mealie – Postgres password (prod)/credential')"
   ```
   (Or paste manually.)
3. **Deploy**:
   ```bash
   just deploy-prod
   ```
4. **Wait** ~90s for cert-manager to issue the TLS cert via DNS-01. Verify:
   ```bash
   export KUBECONFIG=~/.kube/mealie-prod.yaml
   kubectl -n mealie get cert,ingress,pods
   ```
5. **Smoke test** against real HTTPS:
   ```bash
   just smoke-url https://mealie.jenkinz.net
   ```
6. **Rotate the admin password** via the Mealie UI immediately (default credentials
   are `changeme@example.com` / `MyPassword`). Update 1Password.
7. **Bootstrap SMTP** so password resets and household invitations work. See
   [`k8s/smtp/README.md`](k8s/smtp/README.md) for Resend signup and the
   Cloudflare DNS records. Then:
   ```bash
   export SMTP_USER=resend
   export SMTP_PASSWORD="$(op read 'op://Personal/Resend – API key (mealie-prod)/credential')"
   just smtp-bootstrap
   kubectl -n mealie rollout restart deployment/mealie
   ```
8. **Bootstrap observability** (in-cluster Prometheus + Grafana + Alertmanager
   via kube-prometheus-stack). See [`k8s/observability/README.md`](k8s/observability/README.md)
   for the Cloudflare DNS record for `grafana.jenkinz.net` and the Uptime Robot
   external check setup. Then:
   ```bash
   # One-time: enable Traefik /metrics
   KUBECONFIG=~/.kube/mealie-prod.yaml kubectl apply -f k8s/observability/traefik-metrics.yaml

   # Seed the grafana-admin Secret
   export GRAFANA_ADMIN_USER=admin
   export GRAFANA_ADMIN_PASSWORD="$(op read 'op://Personal/Mealie – Grafana admin (prod)/password')"
   just grafana-admin-bootstrap

   # Redeploy to roll out the stack (Prometheus, Grafana, Alertmanager, node-exporter, ...)
   just deploy-prod
   ```
   Once up, log into `https://grafana.jenkinz.net`. The Mealie Overview
   dashboard auto-imports; the 5 PrometheusRule alerts are already active.

## Configuration

### Environment-specific Values

| File | Purpose |
|------|---------|
| `helm/mealie/values.yaml` | Default values |
| `helm/values/dev.yaml` | Local development (k3d + Tilt) |
| `helm/values/prod.yaml` | Production (Hetzner + public HTTPS). Secrets are empty in the file and injected at deploy-time. |

### Key Configuration Options

```yaml
mealie:
  timezone: "Europe/Amsterdam"
  baseUrl: "http://mealie.local"
  allowSignup: true

postgresql:
  enabled: false  # Uses built-in postgres deployment

externalDatabase:
  user: mealie
  password: mealie-dev-password  # Change in production!
  database: mealie
```

## Roadmap

Tracked as OpenSpec changes under `openspec/changes/`. See
[`openspec/project.md`](openspec/project.md) for the full phase plan.

- [x] **Phase 0**: Local MVP (k3d + Helm + Tilt + smoke tests)
- [ ] **Phase 3**: Provision Hetzner VPS + K3s *(in progress — see `openspec/changes/provision-hetzner-k3s`)*
- [ ] **Phase 4**: DNS + TLS (cert-manager + Let's Encrypt)
- [ ] **Phase 5**: Deploy Mealie to prod (GitHub Actions)
- [ ] **Phase 6**: Backups (pg_dump + restic → Backblaze B2)
- [ ] **Phase 7**: Email (Gmail SMTP)
- [ ] **Phase 8**: Observability (Grafana Cloud + Alloy agent)

## Security Notes

⚠️ **For Production Use:**
- Change default database passwords
- Use [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) for secret management
- Enable TLS via cert-manager
- Review and restrict network policies

## License

MIT
