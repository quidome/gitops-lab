#!/usr/bin/env bash
# Copy a fresh admin kubeconfig from the k3s server to this workstation.
# k3s renews its admin certificate on the server when it starts, but the copy
# on the workstation does not change: run this after each k3s renewal.
# Usage: fetch-kubeconfig.sh [host] [server-url]
set -euo pipefail

host="${1:-kube2}"
server="${2:-https://172.16.40.76:6443}"
target="${KUBECONFIG:-$HOME/.kube/config}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# k3s.yaml is readable by root only. Copy it to a private file in the home
# directory on the host, fetch it, delete it. The ssh output is not captured, so
# the sudo password prompt shows on the terminal.
remote_copy=".k3s-kubeconfig.tmp"
echo "Copying k3s.yaml on $host (sudo may ask for your password)..."
ssh -t "$host" "sudo install -m 600 -o \"\$(id -un)\" /etc/rancher/k3s/k3s.yaml ~/$remote_copy"
# From here on, delete the copy on the host also when a later step fails
trap 'rm -f "$tmp"; ssh "$host" rm -f "$remote_copy" >/dev/null 2>&1 || true' EXIT
scp -q "$host:$remote_copy" "$tmp"

# k3s.yaml points at 127.0.0.1; use the address of the server instead
kubectl --kubeconfig "$tmp" config set-cluster default --server="$server" >/dev/null

# Use the new file only when it works
kubectl --kubeconfig "$tmp" get --raw /readyz >/dev/null

if [[ -f "$target" ]]; then
  backup="$target.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$target" "$backup"
  echo "Old kubeconfig: $backup"
fi
install -m 600 "$tmp" "$target"

echo "New kubeconfig: $target"
kubectl --kubeconfig "$target" config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -enddate 2>/dev/null \
  || echo "(install openssl to see the expiry date of the client certificate)"
