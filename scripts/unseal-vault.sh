#!/usr/bin/env bash
set -euo pipefail

readonly GOPASS_ENTRY="${1:-personal/vault/prod}"
readonly VAULT_NAMESPACE="${VAULT_NAMESPACE:-security}"
readonly VAULT_POD="${VAULT_POD:-vault-0}"
readonly REQUIRED_KEYS=3

for command in gopass kubectl jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

# Avoid reading the keys if Vault is already unsealed. A sealed Vault returns a
# non-zero status, so tolerate that expected result and let unseal report errors.
status="$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault status -format=json 2>/dev/null || true)"
if jq -e '.initialized == true and .sealed == false' >/dev/null 2>&1 <<< "$status"; then
  printf 'Vault is already unsealed.\n'
  exit 0
fi

# Keep the keys in memory only; do not print them or write them to disk.
if ! secret="$(gopass show "$GOPASS_ENTRY")"; then
  printf 'Could not read gopass entry: %s\n' "$GOPASS_ENTRY" >&2
  exit 1
fi
unseal_keys=()
while IFS= read -r line; do
  unseal_keys+=("$line")
done <<< "$secret"
unset secret

if (( ${#unseal_keys[@]} < REQUIRED_KEYS )); then
  printf 'Gopass entry must contain at least %d unseal keys\n' "$REQUIRED_KEYS" >&2
  unset unseal_keys
  exit 1
fi

for index in 0 1 2; do
  key="${unseal_keys[$index]}"
  if [[ -z "$key" ]]; then
    printf 'Unseal key %d is empty\n' "$((index + 1))" >&2
    exit 1
  fi

  printf 'Applying unseal key %d/%d...\n' "$((index + 1))" "$REQUIRED_KEYS"
  # Use Vault's stdin input so the key does not appear in a process argument list.
  if ! printf '%s\n' "$key" | kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    vault write sys/unseal key=- >/dev/null; then
    unset unseal_keys key
    exit 1
  fi
done

unset unseal_keys key
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault status
