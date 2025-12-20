# Local Development Guide

## Prerequisites

- [Minikube](https://minikube.sigs.k8s.io/docs/start/) installed
- [Helm](https://helm.sh/docs/intro/install/) 3.x+ installed
- [Tilt](https://docs.tilt.dev/install.html) installed (optional, for hot-reload)
- kubectl configured

## Quick Start

### 1. Start Minikube

```bash
minikube start
minikube addons enable ingress
minikube addons enable dashboard
```

### 2. Deploy with Helm

```bash
helm upgrade --install mealie ./helm/mealie \
  -f ./helm/values/dev.yaml \
  -n mealie \
  --create-namespace \
  --wait
```

### 3. Access Mealie

**Option A: Port Forward (simplest)**
```bash
kubectl port-forward -n mealie svc/mealie 9000:9000
# Visit http://localhost:9000
```

**Option B: Ingress (requires tunnel)**
```bash
# Terminal 1: Start tunnel
minikube tunnel

# Add to /etc/hosts:
# 127.0.0.1 mealie.local

# Visit http://mealie.local
```

## Using Tilt (Hot Reload Development)

```bash
tilt up
# Open http://localhost:10350 for Tilt UI
# Mealie available at http://localhost:9000
```

## Default Credentials

On first access, create an admin account through the Mealie UI.

**PostgreSQL:**
- Host: `mealie-postgres` (in-cluster) or `localhost:5432` (port-forwarded)
- User: `mealie`
- Password: `mealie-dev-password`
- Database: `mealie`

## Useful Commands

```bash
# Check pod status
kubectl get pods -n mealie

# View Mealie logs
kubectl logs -n mealie -l app.kubernetes.io/name=mealie -f

# View PostgreSQL logs
kubectl logs -n mealie -l app.kubernetes.io/name=mealie-postgres -f

# Restart Mealie
kubectl rollout restart deployment/mealie -n mealie

# Uninstall
helm uninstall mealie -n mealie
kubectl delete namespace mealie
```

## Troubleshooting

**Mealie not starting:**
- Check PostgreSQL is running: `kubectl get pods -n mealie`
- Check Mealie logs for DB connection errors

**Ingress not working:**
- Ensure `minikube tunnel` is running
- Verify ingress controller: `kubectl get pods -n ingress-nginx`
- Check ingress status: `kubectl get ingress -n mealie`
