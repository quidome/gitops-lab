#!/usr/bin/env bash
set -euo pipefail

readonly VAULT_NAMESPACE="${VAULT_NAMESPACE:-security}"
readonly VAULT_POD="${VAULT_POD:-vault-0}"
readonly GITOPS_NAMESPACE="${GITOPS_NAMESPACE:-gitops}"
readonly VAULT_POLICY="${VAULT_POLICY:-vals-reader}"
readonly TOKEN_PERIOD="${TOKEN_PERIOD:-8760h}"
readonly GOPASS_ENTRY="${VAULT_TOKEN_GOPASS_ENTRY:-personal/vault/prod/root-token}"

usage() {
  printf 'Usage: %s {status|refresh}\n' "$0"
}

require_commands() {
  local command

  for command in "$@"; do
    if ! command -v "$command" >/dev/null 2>&1; then
      printf 'Required command not found: %s\n' "$command" >&2
      exit 1
    fi
  done
}

decode_base64() {
  if base64 --decode </dev/null >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

status() {
  require_commands kubectl jq base64

  local vault_status_json current_token lookup_json

  # Vault returns exit code 2 while sealed, so preserve and inspect its JSON.
  vault_status_json="$(
    kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault status -format=json 2>/dev/null || true
  )"
  if [[ -z "$vault_status_json" ]]; then
    printf 'Could not retrieve Vault status.\n' >&2
    return 1
  fi

  printf 'Vault status:\n'
  printf '%s\n' "$vault_status_json" | jq '{initialized, sealed, version}'

  if ! printf '%s\n' "$vault_status_json" | jq -e '.initialized == true and .sealed == false' >/dev/null; then
    printf 'Vault is not ready for token access.\n' >&2
    return 1
  fi

  if ! current_token="$(
    kubectl get secret vault-token -n "$GITOPS_NAMESPACE" \
      -o jsonpath='{.data.token}' | decode_base64
  )"; then
    printf 'Could not read %s/vault-token.\n' "$GITOPS_NAMESPACE" >&2
    return 1
  fi
  if [[ -z "$current_token" ]]; then
    printf '%s/vault-token is empty.\n' "$GITOPS_NAMESPACE" >&2
    return 1
  fi

  # Only print selected metadata; never print the token or accessor.
  if ! lookup_json="$(
    printf '%s\n' "$current_token" |
      kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
        sh -c 'IFS= read -r VAULT_TOKEN && export VAULT_TOKEN && exec vault token lookup -format=json' \
        2>/dev/null
  )"; then
    printf 'ArgoCD vals-reader token: invalid or rejected by Vault.\n' >&2
    return 1
  fi

  printf 'ArgoCD vals-reader token:\n'
  printf '%s\n' "$lookup_json" |
    jq '.data | {display_name, policies, ttl, expire_time, renewable, orphan}'
}

refresh() {
  require_commands kubectl jq base64

  local management_token token_json new_token current_token
  management_token="${VAULT_TOKEN:-}"

  if [[ -z "$management_token" ]]; then
    require_commands gopass
    if ! management_token="$(gopass show "$GOPASS_ENTRY")"; then
      printf 'Could not read gopass entry: %s\n' "$GOPASS_ENTRY" >&2
      return 1
    fi
  fi

  if [[ "$management_token" == *$'\n'* ]]; then
    printf 'Management token must be a single line.\n' >&2
    return 1
  fi
  if [[ -z "$management_token" ]]; then
    printf 'Management token cannot be empty.\n' >&2
    return 1
  fi

  if ! current_token="$(
    kubectl get secret vault-token -n "$GITOPS_NAMESPACE" \
      -o jsonpath='{.data.token}' | decode_base64
  )"; then
    printf 'Could not read the existing %s/vault-token.\n' "$GITOPS_NAMESPACE" >&2
    return 1
  fi
  if [[ -z "$current_token" ]]; then
    printf '%s/vault-token is empty.\n' "$GITOPS_NAMESPACE" >&2
    return 1
  fi

  printf 'Creating a new %s token...\n' "$VAULT_POLICY"
  if ! token_json="$(
    printf '%s\n' "$management_token" |
      kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
        sh -c 'IFS= read -r VAULT_TOKEN && export VAULT_TOKEN && exec vault token create -policy="$1" -period="$2" -display-name="$1" -format=json' \
        sh "$VAULT_POLICY" "$TOKEN_PERIOD"
  )"; then
    printf 'Failed to create the Vault token.\n' >&2
    return 1
  fi

  if ! new_token="$(printf '%s' "$token_json" | jq -er '.auth.client_token // empty')"; then
    printf 'Vault did not return a client token.\n' >&2
    return 1
  fi

  printf 'Updating %s/%s...\n' "$GITOPS_NAMESPACE" "vault-token"
  if ! printf '%s' "$new_token" |
    kubectl create secret generic vault-token \
      -n "$GITOPS_NAMESPACE" \
      --from-file=token=/dev/stdin \
      --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null; then
    printf 'Failed to update the Kubernetes secret.\n' >&2
    return 1
  fi

  printf 'Restarting ArgoCD repo-server...\n'
  kubectl rollout restart deployment/argocd-repo-server -n "$GITOPS_NAMESPACE" >/dev/null
  kubectl rollout status deployment/argocd-repo-server -n "$GITOPS_NAMESPACE"

  printf 'Revoking the previous Vault token...\n'
  if ! printf '%s\n' "$current_token" |
    kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
      sh -c 'IFS= read -r VAULT_TOKEN && export VAULT_TOKEN && exec vault token revoke -self' \
      >/dev/null; then
    printf 'New token is active, but the previous token could not be revoked.\n' >&2
    return 1
  fi

  printf 'Vault token refreshed successfully.\n'
}

if (( $# != 1 )); then
  usage >&2
  exit 64
fi

case "$1" in
  status)
    status
    ;;
  refresh)
    refresh
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
