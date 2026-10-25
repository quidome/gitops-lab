# Common operator tasks. Run `just` to list them.
# Recipes stay short; longer logic lives in scripts/.

set shell := ["bash", "-euo", "pipefail", "-c"]

gitops_ns := "gitops"

# List recipes; private so it does not show in its own list
[private]
default:
    @just --list

# Unseal Vault with the first 3 keys from gopass
unseal entry="personal/vault/prod":
    ./scripts/unseal-vault.sh {{ quote(entry) }}

# Show Vault seal status
vault-status:
    kubectl exec -n security vault-0 -- vault status

# Check or refresh the Vals token for ArgoCD (status|refresh)
vault-token action="status":
    ./scripts/refresh-vault-token.sh {{ quote(action) }}

# Start a manual Renovate run
renovate: (job "gitops" "renovate")

# Start a one-off job from a cronjob
job namespace cronjob:
    kubectl create job -n {{ quote(namespace) }} --from=cronjob/{{ cronjob }} {{ cronjob }}-manual-$(date +%s)

# Hard refresh and sync an ArgoCD app, then wait for the result
sync app:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl -n {{ gitops_ns }} annotate application {{ quote(app) }} argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    kubectl -n {{ gitops_ns }} patch application {{ quote(app) }} --type merge \
      -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}' >/dev/null
    # Give the controller time to start the operation before we poll it.
    sleep 5
    for _ in $(seq 1 60); do
      phase=$(kubectl -n {{ gitops_ns }} get application {{ quote(app) }} -o jsonpath='{.status.operationState.phase}')
      [[ "$phase" != "Running" ]] && break
      sleep 5
    done
    kubectl -n {{ gitops_ns }} get application {{ quote(app) }} \
      -o custom-columns='NAME:.metadata.name,OPERATION:.status.operationState.phase,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'

# List ArgoCD apps that are not Synced and Healthy
apps:
    @kubectl get application -n {{ gitops_ns }} --no-headers \
      | awk '$2 != "Synced" || $3 != "Healthy"' \
      | { grep . || echo "All apps are Synced and Healthy."; }

# Remove stuck finalizers from a namespace
finalizers namespace:
    ./scripts/remove-namespace-finalizers.sh {{ quote(namespace) }}

# List all resources in a namespace
resources namespace *args:
    python scripts/list_namespace_resources.py {{ quote(namespace) }} {{ args }}
