# Mealie Local Development
# Primary workflow: just up / just down

set shell := ["bash", "-uc"]

namespace  := "mealie"
cluster    := "mealie-dev"

# Production VPS
vps_name   := "mealie-prod"
vps_type   := "cx33"
vps_image  := "ubuntu-24.04"
# Default region; override at runtime with `VPS_REGION=hel1 just vps-create`.
# Known EU options: fsn1 (Falkenstein), nbg1 (Nuremberg), hel1 (Helsinki).
vps_region := env_var_or_default("VPS_REGION", "nbg1")
vps_sshkey := "andy-laptop"
vps_user   := "andy"

# List recipes
default:
    @just --list

# ─────────────────────────────────────────────────────────────────────────────
# Main Workflow
# ─────────────────────────────────────────────────────────────────────────────

# Start local dev (k3d + tilt)
up:
    @if ! k3d cluster list {{ cluster }} >/dev/null 2>&1; then \
        echo "Creating k3d cluster {{ cluster }}..." ; \
        k3d cluster create {{ cluster }} --wait ; \
    elif ! docker ps --format '{{{{.Names}}}}' | grep -q "^k3d-{{ cluster }}-server-0$"; then \
        echo "Starting k3d cluster {{ cluster }}..." ; \
        k3d cluster start {{ cluster }} --wait ; \
    fi
    @kubectl config use-context k3d-{{ cluster }} >/dev/null
    tilt up

# Stop tilt (keeps k3d cluster running)
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
# Seeding
# ─────────────────────────────────────────────────────────────────────────────

# Run seed script (creates admin@test.com / test)
seed:
    ./scripts/seed.sh http://localhost:9000/api

# ─────────────────────────────────────────────────────────────────────────────
# Smoke tests
# ─────────────────────────────────────────────────────────────────────────────

# Run smoke tests against the local Tilt stack
smoke:
    ./scripts/smoke-test.sh http://localhost:9000

# Run smoke tests against an arbitrary URL (e.g. just smoke-url https://mealie.jenkinz.net)
smoke-url URL:
    ./scripts/smoke-test.sh {{ URL }}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

# Full cleanup (tilt down + delete namespace + delete cluster)
clean:
    -tilt down
    -kubectl delete namespace {{ namespace }} --ignore-not-found
    -k3d cluster delete {{ cluster }}

# Stop the k3d cluster (preserves definition for next `just up`)
stop:
    k3d cluster stop {{ cluster }}

# ─────────────────────────────────────────────────────────────────────────────
# Production VPS (Hetzner Cloud, see infra/README.md)
# ─────────────────────────────────────────────────────────────────────────────

# Provision the prod VPS (idempotent: no-op if it already exists)
vps-create:
    #!/usr/bin/env bash
    set -euo pipefail
    if hcloud server describe {{ vps_name }} >/dev/null 2>&1; then
        echo "Server {{ vps_name }} already exists — skipping create."
        hcloud server describe {{ vps_name }} -o format='{{{{.PublicNet.IPv4.IP}}}}'
        exit 0
    fi
    if [[ ! -f ~/.ssh/id_ed25519.pub ]]; then
        echo "ERROR: ~/.ssh/id_ed25519.pub not found. Generate one with ssh-keygen." >&2
        exit 1
    fi
    if [[ -z "${TS_AUTHKEY:-}" ]]; then
        echo "ERROR: TS_AUTHKEY is not set. Generate a reusable auth key at" >&2
        echo "       https://login.tailscale.com/admin/settings/keys and export it, e.g.:" >&2
        echo "       export TS_AUTHKEY=\$(op read 'op://Personal/Tailscale mealie-prod auth key/credential')" >&2
        exit 1
    fi
    export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
    export TS_AUTHKEY
    USER_DATA=$(envsubst '$SSH_PUBKEY $TS_AUTHKEY' < infra/cloud-init.yaml)
    echo "Creating {{ vps_name }} ({{ vps_type }} in {{ vps_region }})..."
    hcloud server create \
        --name {{ vps_name }} \
        --image {{ vps_image }} \
        --type {{ vps_type }} \
        --location {{ vps_region }} \
        --ssh-key {{ vps_sshkey }} \
        --user-data-from-file <(echo "$USER_DATA")
    echo ""
    echo "Public IPv4: $(hcloud server ip {{ vps_name }})"
    echo "cloud-init runs in the background; wait ~60-90s for Tailscale + K3s."
    echo "Then: just vps-kubeconfig"

# SSH into the prod VPS (clears stale host-key entry after a destroy+recreate)
vps-ssh:
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(hcloud server ip {{ vps_name }})
    ssh-keygen -R "$IP" >/dev/null 2>&1 || true
    ssh -o StrictHostKeyChecking=accept-new {{ vps_user }}@"$IP"

# Fetch kubeconfig from the prod VPS; server URL points at the VPS tailnet IP
vps-kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(hcloud server ip {{ vps_name }})
    mkdir -p ~/.kube
    # Clear stale host-key entry if the VPS was destroyed and recreated.
    ssh-keygen -R "$IP" >/dev/null 2>&1 || true
    # Grab the kubeconfig and the tailnet IP in one SSH round-trip.
    TS_IP=$(ssh -o StrictHostKeyChecking=accept-new {{ vps_user }}@"$IP" 'tailscale ip -4' | head -1)
    if [[ -z "$TS_IP" ]]; then
        echo "ERROR: could not read tailscale IP from VPS. Is Tailscale up?" >&2
        exit 1
    fi
    ssh {{ vps_user }}@"$IP" 'cat /etc/rancher/k3s/k3s.yaml' \
        | sed "s/127.0.0.1/$TS_IP/" \
        > ~/.kube/mealie-prod.yaml
    chmod 600 ~/.kube/mealie-prod.yaml
    echo "Wrote ~/.kube/mealie-prod.yaml (server URL: https://$TS_IP:6443)"
    echo ""
    echo "Next:"
    echo "  export KUBECONFIG=~/.kube/mealie-prod.yaml"
    echo "  kubectl get nodes      # requires Tailscale running on your laptop"

# ─────────────────────────────────────────────────────────────────────────────
# Production backups (restic → Backblaze B2; see k8s/backups/README.md)
# ─────────────────────────────────────────────────────────────────────────────

# Create/update the backup-credentials Secret from env vars (idempotent)
backup-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    missing=""
    for var in B2_KEY_ID B2_APP_KEY RESTIC_PASSWORD POSTGRES_PASSWORD; do
        if [[ -z "${!var:-}" ]]; then
            missing="$missing $var"
        fi
    done
    if [[ -n "$missing" ]]; then
        echo "ERROR: env vars not set:$missing" >&2
        echo "See k8s/backups/README.md for the required values and 1Password entries." >&2
        exit 1
    fi
    if [[ ! -f ~/.kube/mealie-prod.yaml ]]; then
        echo "ERROR: ~/.kube/mealie-prod.yaml not found. Run 'just vps-kubeconfig' first." >&2
        exit 1
    fi
    export KUBECONFIG="$HOME/.kube/mealie-prod.yaml"
    kubectl create namespace {{ namespace }} --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n {{ namespace }} create secret generic backup-credentials \
        --from-literal=B2_ACCOUNT_ID="$B2_KEY_ID" \
        --from-literal=B2_ACCOUNT_KEY="$B2_APP_KEY" \
        --from-literal=RESTIC_PASSWORD="$RESTIC_PASSWORD" \
        --from-literal=RESTIC_REPOSITORY="b2:jenkinz-mealie-backup:mealie" \
        --from-literal=POSTGRES_HOST="mealie-postgres" \
        --from-literal=POSTGRES_USER="mealie" \
        --from-literal=POSTGRES_DB="mealie" \
        --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "✓ backup-credentials Secret created/updated in the {{ namespace }} namespace."
    echo ""
    echo "Next:"
    echo "  just backup-now           # trigger an ad-hoc backup"
    echo "  just restore-drill        # verify end-to-end restore"

# Trigger an ad-hoc backup (spawns a Job from the CronJob template)
backup-now:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG="$HOME/.kube/mealie-prod.yaml"
    JOB_NAME="mealie-backup-manual-$(date +%s)"
    kubectl -n {{ namespace }} create job "$JOB_NAME" --from=cronjob/mealie-backup
    echo "→ tailing logs for $JOB_NAME..."
    sleep 3
    kubectl -n {{ namespace }} logs -f job/"$JOB_NAME" || true
    kubectl -n {{ namespace }} wait --for=condition=complete job/"$JOB_NAME" --timeout=5m
    echo "✓ backup job $JOB_NAME completed."

# Restore the latest backup into a scratch namespace + verify with a real query
restore-drill:
    #!/usr/bin/env bash
    export KUBECONFIG="$HOME/.kube/mealie-prod.yaml"
    exec scripts/restore-drill.sh

# ─────────────────────────────────────────────────────────────────────────────
# Production SMTP (Resend → no-reply@mealie.jenkinz.net; see k8s/smtp/README.md)
# ─────────────────────────────────────────────────────────────────────────────

# Create/update the mealie-smtp Secret from SMTP_USER + SMTP_PASSWORD (idempotent)
smtp-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    missing=""
    for var in SMTP_USER SMTP_PASSWORD; do
        if [[ -z "${!var:-}" ]]; then
            missing="$missing $var"
        fi
    done
    if [[ -n "$missing" ]]; then
        echo "ERROR: env vars not set:$missing" >&2
        echo "See k8s/smtp/README.md for the required values and 1Password entries." >&2
        echo "For Resend: SMTP_USER=resend, SMTP_PASSWORD=<Resend API key>." >&2
        exit 1
    fi
    if [[ ! -f ~/.kube/mealie-prod.yaml ]]; then
        echo "ERROR: ~/.kube/mealie-prod.yaml not found. Run 'just vps-kubeconfig' first." >&2
        exit 1
    fi
    export KUBECONFIG="$HOME/.kube/mealie-prod.yaml"
    kubectl create namespace {{ namespace }} --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n {{ namespace }} create secret generic mealie-smtp \
        --from-literal=SMTP_USER="$SMTP_USER" \
        --from-literal=SMTP_PASSWORD="$SMTP_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "✓ mealie-smtp Secret created/updated in the {{ namespace }} namespace."
    echo ""
    echo "Next:"
    echo "  just deploy-prod                             # pick up envFrom on rollout"
    echo "  # then trigger a password reset in the Mealie UI to verify delivery"

# ─────────────────────────────────────────────────────────────────────────────
# Production observability (kube-prometheus-stack; see k8s/observability/README.md)
# ─────────────────────────────────────────────────────────────────────────────

# Create/update the grafana-admin Secret from GRAFANA_ADMIN_USER + GRAFANA_ADMIN_PASSWORD (idempotent)
grafana-admin-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    missing=""
    for var in GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD; do
        if [[ -z "${!var:-}" ]]; then
            missing="$missing $var"
        fi
    done
    if [[ -n "$missing" ]]; then
        echo "ERROR: env vars not set:$missing" >&2
        echo "See k8s/observability/README.md for the required values and 1Password entries." >&2
        exit 1
    fi
    if [[ ! -f ~/.kube/mealie-prod.yaml ]]; then
        echo "ERROR: ~/.kube/mealie-prod.yaml not found. Run 'just vps-kubeconfig' first." >&2
        exit 1
    fi
    export KUBECONFIG="$HOME/.kube/mealie-prod.yaml"
    kubectl create namespace {{ namespace }} --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n {{ namespace }} create secret generic grafana-admin \
        --from-literal=admin-user="$GRAFANA_ADMIN_USER" \
        --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "✓ grafana-admin Secret created/updated in the {{ namespace }} namespace."
    echo ""
    echo "Next:"
    echo "  kubectl apply -f k8s/observability/traefik-metrics.yaml   # one-time: enable Traefik /metrics"
    echo "  just deploy-prod                                          # rolls out the full stack"
    echo "  # open https://grafana.jenkinz.net and log in"

# ─────────────────────────────────────────────────────────────────────────────
# Production Mealie deploy (helm upgrade --install against prod cluster)
# ─────────────────────────────────────────────────────────────────────────────

# Deploy Mealie to prod with secrets injected from env vars
deploy-prod:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "${MEALIE_SECRET_KEY:-}" ]]; then
        echo "ERROR: MEALIE_SECRET_KEY is not set. Grab from 1Password first:" >&2
        echo "       export MEALIE_SECRET_KEY='...'" >&2
        exit 1
    fi
    if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
        echo "ERROR: POSTGRES_PASSWORD is not set. Grab from 1Password first:" >&2
        echo "       export POSTGRES_PASSWORD='...'" >&2
        exit 1
    fi
    if [[ ! -f ~/.kube/mealie-prod.yaml ]]; then
        echo "ERROR: ~/.kube/mealie-prod.yaml not found. Run 'just vps-kubeconfig' first." >&2
        exit 1
    fi
    export KUBECONFIG="$HOME/.kube/mealie-prod.yaml"
    echo "→ Ensuring mealie namespace exists..."
    kubectl create namespace {{ namespace }} --dry-run=client -o yaml | kubectl apply -f -
    echo "→ helm upgrade --install..."
    helm upgrade --install mealie ./helm/mealie \
        --namespace {{ namespace }} \
        -f helm/values/prod.yaml \
        --set "mealie.secretKey=$MEALIE_SECRET_KEY" \
        --set "externalDatabase.password=$POSTGRES_PASSWORD" \
        --wait --timeout 5m
    echo ""
    echo "Deployed. Next:"
    echo "  kubectl -n {{ namespace }} get pods,cert,ingress"
    echo "  # wait ~90s for cert-manager to issue the TLS cert, then:"
    echo "  just smoke-url https://mealie.jenkinz.net"

# ─────────────────────────────────────────────────────────────────────────────
# Production TLS (cert-manager + Let's Encrypt via Cloudflare DNS-01)
# ─────────────────────────────────────────────────────────────────────────────

# Install cert-manager + Cloudflare-DNS-01 ClusterIssuers on the current cluster
tls-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "${CF_API_TOKEN:-}" ]]; then
        echo "ERROR: CF_API_TOKEN is not set. Grab from 1Password, then:" >&2
        echo "       export CF_API_TOKEN='...' && just tls-bootstrap" >&2
        exit 1
    fi
    echo "→ Adding jetstack Helm repo..."
    helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
    helm repo update jetstack >/dev/null
    echo "→ Installing cert-manager..."
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --set installCRDs=true \
        --wait --timeout 5m
    echo "→ Creating/updating cloudflare-api-token Secret..."
    kubectl create secret generic cloudflare-api-token \
        --namespace cert-manager \
        --from-literal=api-token="$CF_API_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "→ Applying ClusterIssuers..."
    kubectl apply -f k8s/cert-manager/cluster-issuer-staging.yaml
    kubectl apply -f k8s/cert-manager/cluster-issuer-prod.yaml
    echo ""
    echo "Done. Verify with:"
    echo "  kubectl -n cert-manager get pods"
    echo "  kubectl get clusterissuers"
    echo "Then prove end-to-end: just tls-test"

# End-to-end proof that DNS-01 cert issuance works (staging cert, self-cleaning)
tls-test:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl apply -f k8s/cert-manager/test-certificate.yaml
    echo "→ Waiting for staging cert to reach Ready (timeout 3 min)..."
    for i in $(seq 1 18); do
        STATUS=$(kubectl -n default get cert tls-test -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$STATUS" == "True" ]]; then
            echo "  tls-test is Ready after ${i}0s."
            break
        fi
        echo "  attempt $i/18 — status: ${STATUS:-unknown}"
        sleep 10
    done
    if [[ "$STATUS" != "True" ]]; then
        echo "ERROR: tls-test did not reach Ready. Inspecting..." >&2
        kubectl -n default describe cert tls-test >&2 || true
        kubectl -n default delete -f k8s/cert-manager/test-certificate.yaml --ignore-not-found
        exit 1
    fi
    echo "→ Cleaning up test cert..."
    kubectl -n default delete -f k8s/cert-manager/test-certificate.yaml
    kubectl -n default delete secret tls-test-tls --ignore-not-found
    echo "tls-test passed ✓"

# ─────────────────────────────────────────────────────────────────────────────
# Production VPS lifecycle (continued)
# ─────────────────────────────────────────────────────────────────────────────

# Destroy the prod VPS (requires typed DESTROY confirmation)
vps-destroy:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! hcloud server describe {{ vps_name }} >/dev/null 2>&1; then
        echo "No {{ vps_name }} server exists — nothing to destroy."
        exit 0
    fi
    read -p "Type DESTROY to delete {{ vps_name }}: " CONFIRM
    if [[ "$CONFIRM" != "DESTROY" ]]; then
        echo "Aborted."
        exit 1
    fi
    hcloud server delete {{ vps_name }}
    echo "Deleted {{ vps_name }}."
