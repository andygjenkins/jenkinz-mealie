# Mealie Kubernetes Deployment

Self-hosted [Mealie](https://mealie.io) recipe management application on Kubernetes.

## Overview

This repository contains Kubernetes manifests and Helm charts for deploying Mealie with PostgreSQL to a Kubernetes cluster. Designed for both local development (Minikube) and production deployment (K3s on Hetzner).

## Features

- 🍳 **Mealie v2.6.0** - Recipe management with web scraping, meal planning
- 🐘 **PostgreSQL 15** - Reliable database backend
- ⎈ **Helm Charts** - Templated, reusable Kubernetes manifests
- 🔄 **Tilt** - Hot-reload local development
- 🌐 **Ingress** - NGINX ingress with TLS support (production)

## Quick Start (Local Development)

### Prerequisites

- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [Helm](https://helm.sh/docs/intro/install/) 3.x+
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

### Deploy

```bash
# Start Minikube with ingress
minikube start
minikube addons enable ingress

# Deploy Mealie
helm upgrade --install mealie ./helm/mealie \
  -f ./helm/values/dev.yaml \
  -n mealie \
  --create-namespace \
  --wait

# Access Mealie
kubectl port-forward -n mealie svc/mealie 9000:9000
# Visit http://localhost:9000
```

See [LOCAL_DEV.md](LOCAL_DEV.md) for detailed development instructions.

## Project Structure

```
.
├── helm/
│   ├── mealie/           # Main Helm chart
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   └── values/
│       └── dev.yaml      # Development overrides
├── Tiltfile              # Local dev with Tilt
├── LOCAL_DEV.md          # Development guide
└── README.md
```

## Configuration

### Environment-specific Values

| File | Purpose |
|------|---------|
| `helm/mealie/values.yaml` | Default values |
| `helm/values/dev.yaml` | Local development |
| `helm/values/prod.yaml` | Production (create as needed) |

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

- [x] **Phase 0**: Local MVP (Minikube + Helm)
- [ ] **Phase 1**: Infrastructure (Hetzner VPS + K3s)
- [ ] **Phase 2**: Core K8s (Traefik + cert-manager)
- [ ] **Phase 3**: Production deploy
- [ ] **Phase 4**: GitOps (ArgoCD + sealed-secrets)
- [ ] **Phase 5**: Monitoring (Prometheus + Grafana)
- [ ] **Phase 6**: Backup (CronJob + Backblaze B2)

## Security Notes

⚠️ **For Production Use:**
- Change default database passwords
- Use [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) for secret management
- Enable TLS via cert-manager
- Review and restrict network policies

## License

MIT
