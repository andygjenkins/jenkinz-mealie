# Project Context

## Purpose
Self-host Mealie, an open-source recipe management application, on a lightweight Kubernetes cluster for family use. The deployment emphasizes reliability, security, and low operational cost (~€6/month) while providing a production-grade infrastructure foundation.

**Target URL**: https://mealie.jenkinz.net

## Tech Stack

### Infrastructure
- **VPS**: Hetzner CPX21 (4 vCPU, 8GB RAM, 80GB SSD)
- **OS**: Ubuntu 24.04 LTS
- **Kubernetes**: K3s (lightweight distribution)
- **Firewall**: UFW

### Kubernetes Components
- **Ingress**: Traefik
- **TLS**: cert-manager + Let's Encrypt
- **Secrets**: sealed-secrets (git-safe encryption)
- **GitOps**: ArgoCD
- **Package Manager**: Helm 4 (released November 2025)

### Application Stack
- **Application**: Mealie (recipe management)
- **Database**: PostgreSQL 15
- **Email**: Gmail SMTP (notifications, password resets)

### Observability
- **Metrics**: Prometheus
- **Dashboards**: Grafana

### Development
- **Local Cluster**: Minikube
- **Dev Workflow**: Tilt (hot-reload)

### Backup
- **Jobs**: Kubernetes CronJob (pg_dump)
- **Offsite Storage**: Backblaze B2

## Project Conventions

### Code Style
- Kubernetes manifests use YAML with 2-space indentation
- Use Kustomize for environment overlays (base → dev/prod)
- Helm values files follow upstream chart conventions
- Shell scripts use bash with `set -euo pipefail`

### Architecture Patterns
- **Local-first development**: Build and validate in Minikube/Tilt before cloud deployment
- **GitOps**: All production changes flow through git → ArgoCD
- **Sealed Secrets**: No plaintext secrets in git; use kubeseal for encryption
- **Kustomize overlays**: `k8s/base/` for shared config, `k8s/overlays/{dev,prod}/` for environment-specific

### Testing Strategy
- Each task must include automated test, script, or justfile recipe demonstrating the change
- Integration tests validate DNS, TLS, application health, database connectivity
- Backup/restore procedures must be tested and documented

### Git Workflow
- Ephemeral branches for feature work
- Local merge to main (no upstream push for infrastructure repo)
- Use beads (`bd`) for issue tracking
- Commit messages describe what changed and why

## Domain Context
- **Mealie**: Self-hosted recipe manager with web UI, recipe scraping, meal planning
- **K3s**: Lightweight Kubernetes for edge/IoT, single-binary, uses SQLite by default
- **Traefik**: Cloud-native ingress controller with automatic Let's Encrypt integration
- **sealed-secrets**: Bitnami controller that encrypts secrets for safe git storage

## Important Constraints
- **Budget**: ~€6/month total (Hetzner VPS + Backblaze B2)
- **Availability**: 99%+ uptime (best-effort for self-hosted)
- **Single node**: No HA/multi-node cluster (out of scope)
- **No custom Mealie modifications**: Use upstream Docker image only

## External Dependencies
- **Hetzner Cloud**: VPS hosting
- **Cloudflare**: DNS management for *.jenkinz.net
- **Let's Encrypt**: Free TLS certificates
- **Backblaze B2**: S3-compatible backup storage
- **Gmail SMTP**: Email delivery for notifications

## Repository Structure
```
.
├── SPEC.md                 # Full specification
├── AGENTS.md               # Agent instructions
├── openspec/               # OpenSpec configuration
│   ├── project.md          # This file
│   ├── specs/              # Current truth - what IS built
│   └── changes/            # Proposals - what SHOULD change
├── k8s/
│   ├── base/               # Shared Kubernetes manifests
│   └── overlays/
│       ├── dev/            # Minikube/Tilt overrides
│       └── prod/           # Production overrides
├── argocd/                 # ArgoCD application definitions
├── monitoring/             # Prometheus/Grafana config
├── scripts/                # Backup/restore scripts
├── Tiltfile                # Local development config
└── justfile                # Task runner recipes
```

## Implementation Phases
1. **Phase 0 (P0)**: Local MVP - Validate in Minikube/Tilt
2. **Phase 1 (P1)**: Infrastructure - Provision Hetzner VPS, K3s
3. **Phase 2 (P1)**: Core K8s - Traefik, cert-manager
4. **Phase 3 (P1)**: Production - Deploy Mealie to prod
5. **Phase 4 (P2)**: GitOps - ArgoCD, sealed-secrets
6. **Phase 5 (P2)**: Monitoring - Prometheus, Grafana
7. **Phase 6 (P2)**: Backup - CronJob, Backblaze B2
8. **Phase 7 (P3)**: Email - Gmail SMTP configuration
