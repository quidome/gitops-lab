#!/bin/bash
# Remove finalizers from a Kubernetes namespace.
# Usage: ./remove-namespace-finalizers.sh <namespace>

if [ -z "$1" ]; then
    echo "Usage: $0 <namespace>"
    exit 1
fi

NAMESPACE="$1"

echo "Removing finalizers from namespace: $NAMESPACE"

kubectl get namespace "$NAMESPACE" -o json | \
    jq 'del(.spec.finalizers)' | \
    kubectl replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f -

echo "Done"
