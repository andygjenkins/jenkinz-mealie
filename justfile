# Mealie Local Development
# Primary workflow: just up / just down

set shell := ["bash", "-uc"]

namespace := "mealie"

# List recipes
default:
    @just --list

# ─────────────────────────────────────────────────────────────────────────────
# Main Workflow
# ─────────────────────────────────────────────────────────────────────────────

# Start local dev (minikube + tilt)
up:
    @minikube status > /dev/null 2>&1 || (echo "Starting minikube..." && minikube start && minikube addons enable ingress)
    tilt up

# Stop tilt (keeps minikube running)
down:
    tilt down

# Open Mealie UI
open:
    open http://localhost:9000

# ─────────────────────────────────────────────────────────────────────────────
# Debugging
# ─────────────────────────────────────────────────────────────────────────────

# Show pods
pods:
    kubectl get pods -n {{ namespace }}

# Follow Mealie logs
logs:
    kubectl logs -n {{ namespace }} -l app.kubernetes.io/name=mealie -f

# Follow PostgreSQL logs
logs-db:
    kubectl logs -n {{ namespace }} -l app.kubernetes.io/name=mealie-postgres -f

# Connect to PostgreSQL
psql:
    kubectl exec -it -n {{ namespace }} deployment/mealie-postgres -- psql -U mealie -d mealie

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

# Full cleanup (tilt down + delete namespace)
clean:
    -tilt down
    kubectl delete namespace {{ namespace }} --ignore-not-found

# Stop minikube
stop:
    minikube stop
