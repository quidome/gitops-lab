#!/usr/bin/env bash
# Usage: ./remove-namespace-finalizers.sh <namespace>

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <namespace>"
    exit 1
fi

NS="$1"

echo "Removing finalizers from namespace: $NS"

kubectl get namespace "$NS" -o json | \
    jq '.spec.finalizers = []' | \
    kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f -

echo "Done. Namespace $NS should now delete itself."
