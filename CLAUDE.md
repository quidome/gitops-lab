# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

GitOps-managed home lab Kubernetes infrastructure running on k3s with NixOS. Uses ArgoCD for continuous deployment with Helmfile (new) and Kustomize+Helm (legacy) for templating.

## Architecture

### Directory Structure
- **infrastructure/** - New Helmfile-based infrastructure (security/openbao, security/external-secrets, observability/metrics-server, hardware/node-feature-discovery)
- **infrastructure-legacy/** - Legacy infrastructure using Kustomize-with-Helm plugin (ArgoCD, Cilium, cert-manager, etc.)
- **applications/** - Active user applications deployed via Helmfile (file-sharing/syncthing)
- **applications-legacy/** - Legacy apps using Kustomize-with-Helm plugin (zigbee2mqtt)
- **manual/** - Work-in-progress configurations not yet automated

### Technology Stack
- **Kubernetes**: k3s on NixOS
- **Networking**: Cilium (kube-proxy replacement), Gateway API, External DNS, Pi-hole
- **GitOps**: ArgoCD with ApplicationSets
- **Templating**: Helmfile (new components) and Kustomize + Helm via `kustomize-build-with-helm` plugin (legacy)
- **Storage**: Democratic-CSI with TrueNAS (iSCSI and NFS backends)
- **Secrets**: OpenBao with external-secrets and Sealed Secrets for git-safe encryption (legacy)
- **Certificates**: cert-manager with Cloudflare DNS-01

### Component Patterns

**New (Helmfile-based) — `infrastructure/` and `applications/`:**
```
realm/component/
├── helmfile.yaml        # Helm releases and repositories
└── values.yaml          # Helm value overrides
```

**Legacy (Kustomize-based) — `infrastructure-legacy/` and `applications-legacy/`:**
```
component/
├── kustomization.yaml   # Orchestrates Helm charts and resources
├── ns.yaml              # Namespace definition
├── values.yaml          # Helm value overrides
└── charts/              # Vendored Helm charts (when used)
```

### GitOps Deployment
- New infrastructure/applications use ApplicationSet with Helmfile plugin (`infrastructure/*/*`, `applications/*/*`)
- Legacy infrastructure/applications use ApplicationSet with `kustomize-build-with-helm` plugin
- All ApplicationSets implement retry logic and server-side apply

## Common Commands

### Bootstrap (from workstation)
```bash
# Cilium
helm repo add cilium https://helm.cilium.io && helm repo update
helm install cilium cilium/cilium -n kube-system \
  -f infrastructure-legacy/networking/cilium/values.yaml \
  --version 1.17.6 --set operator.replicas=1

# ArgoCD
kubectl create namespace argocd
kubectl kustomize --enable-helm infrastructure-legacy/controllers/argocd | kubectl apply -f -
kubectl apply -f infrastructure-legacy/controllers/argocd/managed-apps.yaml
```

### OpenBAO Workflow
```bash
# Add a secret
kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="<root-token>" && bao kv put kv/<path> <key>=<value>'

# Read a secret
kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="<root-token>" && bao kv get kv/<path>'

# List secrets
kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="<root-token>" && bao kv list kv/'

# Unseal after pod restart (3 of 5 keys required)
kubectl exec -n security openbao-0 -- bao operator unseal <unseal-key>
```

### Sealed Secrets Workflow (legacy)
```bash
# Create secret from file
kubectl create secret generic myNewSecret --from-file=secret.yaml=document.yaml -o yaml > secret.yaml

# Seal it
cat secret.yaml | kubeseal --controller-namespace kube-system --controller-name sealed-secrets -o yaml

# Re-seal existing secret (strips cluster metadata)
kubectl get secrets <name> -o yaml | \
  yq eval-all 'del(.metadata.annotations, .metadata.labels, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid)' | \
  kubeseal --controller-namespace kube-system --controller-name sealed-secrets -o yaml
```

### Utility Scripts
```bash
# List all resources in a namespace
python list_namespace_resources.py <namespace> [--json]

# Remove stuck namespace finalizers
./remove-namespace-finalizers.sh <namespace>
```

### Validate Kustomize Build (legacy components)
```bash
kubectl kustomize --enable-helm infrastructure-legacy/<category>/<component>
```

## Key Conventions

- **Namespace per component**: Each component gets its own namespace defined in `ns.yaml`
- **Sync-wave annotations**: Control deployment order via `argocd.argoproj.io/sync-wave`
- **Resource limits**: All components should define CPU/memory requests and limits
- **Retain policy**: Storage classes use Retain policy to preserve PVs on deletion

## Infrastructure Migration (In Progress)

Migration from Kustomize+Helm to Helmfile-based infrastructure with domain-based realms. Phases 1-2 are complete; incremental component migration is ongoing.

### Migration Status

**Migrated to `infrastructure/` (Helmfile):**
- `security/openbao` — Secret management (OpenBAO)
- `security/external-secrets` — External Secrets Operator
- `observability/metrics-server` — Metrics server
- `hardware/node-feature-discovery` — Hardware detection

**Remaining in `infrastructure-legacy/` (Kustomize+Helm):**
- `controllers/argocd` — GitOps controller
- `controllers/cert-manager` — Certificate management (secrets migrated to OpenBAO)
- `controllers/sealed-secrets` — Legacy secret encryption
- `networking/cilium` — CNI and kube-proxy replacement
- `networking/external-dns` — DNS automation (secrets migrated to OpenBAO)
- `networking/gateway` — Gateway API resources
- `networking/pihole` — DNS ad-blocking
- `storage/democratic-csi` — iSCSI and NFS storage drivers (secrets migrated to OpenBAO)

### Target Structure
```
infrastructure/
├── gitops/              # Deployment automation
│   └── argocd/
├── security/            # Secrets, certs, access control
│   ├── cert-manager/
│   ├── external-secrets/  ✓ migrated
│   └── openbao/           ✓ migrated
├── networking/          # CNI, DNS, ingress
│   ├── cilium/
│   ├── external-dns/
│   ├── gateway/
│   └── pihole/
├── storage/             # CSI drivers, storage classes
│   └── democratic-csi/
├── observability/       # Metrics, logging, tracing
│   └── metrics-server/    ✓ migrated
└── hardware/            # Hardware detection
    └── node-feature-discovery/  ✓ migrated
```
