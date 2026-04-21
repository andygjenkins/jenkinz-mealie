#!/usr/bin/env bash
# End-to-end restore verification:
#   1. Creates a scratch namespace.
#   2. Copies the backup-credentials Secret into it.
#   3. Runs the restore-drill Job (k8s/backups/restore-drill.yaml) which:
#      - brings up an empty PostgreSQL
#      - pulls the latest restic snapshot from B2
#      - loads it into the scratch DB
#      - queries SELECT count(*) FROM users and fails if 0
#   4. Reports the result and cleans up (or leaves the ns if KEEP=1).
#
# Usage: KUBECONFIG=~/.kube/mealie-prod.yaml scripts/restore-drill.sh
# Or via: just restore-drill

set -euo pipefail

NS="mealie-restore-drill-$(date +%s)"
KEEP="${KEEP:-0}"

cleanup() {
    local rc=$?
    if [[ "$KEEP" = "1" ]] || [[ "$rc" -ne 0 ]]; then
        if [[ "$rc" -ne 0 ]]; then
            echo ""
            echo "Namespace $NS left in place for inspection. Hints:"
            echo "  kubectl -n $NS logs job/restore-drill"
            echo "  kubectl -n $NS describe job/restore-drill"
            echo "  kubectl -n $NS get pods"
            echo "  kubectl delete namespace $NS   # when done"
        fi
    else
        echo "→ cleaning up namespace $NS..."
        kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null || true
    fi
}
trap cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "→ creating scratch namespace $NS..."
kubectl create namespace "$NS" >/dev/null

echo "→ copying backup-credentials secret from mealie to $NS..."
kubectl -n mealie get secret backup-credentials -o yaml \
    | sed "s/namespace: mealie$/namespace: $NS/" \
    | grep -v '^\s*\(resourceVersion\|uid\|creationTimestamp\|selfLink\):' \
    | kubectl apply -n "$NS" -f - >/dev/null

echo "→ applying restore-drill Job..."
kubectl -n "$NS" apply -f "$REPO_ROOT/k8s/backups/restore-drill.yaml" >/dev/null

echo "→ waiting for the pod to be created..."
for i in $(seq 1 30); do
    if kubectl -n "$NS" get pod -l job-name=restore-drill 2>/dev/null | grep -q restore-drill; then
        break
    fi
    sleep 1
done

echo "→ tailing drill logs (will stream until completion)..."
echo ""
# `kubectl logs -f job/...` auto-selects the pod and follows to completion.
kubectl -n "$NS" logs -f job/restore-drill || true

echo ""
echo "→ checking final Job status..."
if kubectl -n "$NS" wait --for=condition=complete job/restore-drill --timeout=30s >/dev/null 2>&1; then
    echo "✓ Restore drill passed end-to-end."
    exit 0
else
    echo "✗ Restore drill FAILED. See logs above."
    exit 1
fi
