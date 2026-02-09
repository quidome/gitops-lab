# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

GitOps-managed home lab Kubernetes infrastructure running on k3s with NixOS. Uses ArgoCD for continuous deployment with Kustomize and Helm for templating.

## Architecture

### Directory Structure
- **infrastructure/** - Core cluster components (ArgoCD, Cilium, cert-manager, storage)
- **applications/** - Active user applications deployed via Helmfile
- **applications-legacy/** - Deprecated apps using Kustomize-with-Helm plugin
- **manual/** - Work-in-progress configurations not yet automated

### Technology Stack
- **Kubernetes**: k3s on NixOS
- **Networking**: Cilium (kube-proxy replacement), Gateway API, External DNS, Pi-hole
- **GitOps**: ArgoCD with ApplicationSets
- **Templating**: Kustomize + Helm (via `kustomize-build-with-helm` plugin)
- **Storage**: Democratic-CSI with TrueNAS (iSCSI and NFS backends)
- **Secrets**: Sealed Secrets for git-safe encryption
- **Certificates**: cert-manager with Cloudflare DNS-01

### Component Pattern
Each infrastructure component follows this structure:
```
component/
├── kustomization.yaml   # Orchestrates Helm charts and resources
├── ns.yaml              # Namespace definition
├── values.yaml          # Helm value overrides
└── charts/              # Vendored Helm charts (when used)
```

### GitOps Deployment
- Infrastructure uses ApplicationSet with Git directory generator
- Applications use Helmfile plugin with path-based namespace extraction
- All ApplicationSets implement retry logic and server-side apply

## Common Commands

### Bootstrap (from workstation)
```bash
# Cilium
helm repo add cilium https://helm.cilium.io && helm repo update
helm install cilium cilium/cilium -n kube-system \
  -f infrastructure/networking/cilium/values.yaml \
  --version 1.17.6 --set operator.replicas=1

# ArgoCD
kubectl create namespace argocd
kubectl kustomize --enable-helm infrastructure/controllers/argocd | kubectl apply -f -
kubectl apply -f infrastructure/controllers/argocd/projects.yaml
```

### Sealed Secrets Workflow
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

### Validate Kustomize Build
```bash
kubectl kustomize --enable-helm infrastructure/<component>
```

## Key Conventions

- **Namespace per component**: Each component gets its own namespace defined in `ns.yaml`
- **Sync-wave annotations**: Control deployment order via `argocd.argoproj.io/sync-wave`
- **Resource limits**: All components should define CPU/memory requests and limits
- **Retain policy**: Storage classes use Retain policy to preserve PVs on deletion

## Planned: Next-Gen Infrastructure

Migration to Helmfile-based infrastructure with domain-based realms.

### Migration Approach (Safe Copy-Then-Delete)

**Phase 1: Copy and redirect**
1. Copy `infrastructure/` → `infrastructure-legacy/`
2. Update `infrastructure/applicationset.yaml` to point to `infrastructure-legacy/*/`
3. Commit and push, wait for ArgoCD to sync and stabilize
4. Verify all apps healthy in ArgoCD UI

**Phase 2: Replace with new structure**
5. Delete old contents from `infrastructure/` (keep only applicationset.yaml)
6. Build new Helmfile-based components in `infrastructure/<realm>/<component>/`
7. Create new ApplicationSet for Helmfile-based infrastructure

**Phase 3: Cleanup**
8. Migrate components incrementally from legacy to new
9. Remove `infrastructure-legacy/` when all components migrated

### Target Structure
```
infrastructure/
├── gitops/              # Deployment automation
│   └── argocd/
├── security/            # Secrets, certs, access control
│   ├── cert-manager/
│   ├── sealed-secrets/
│   └── vault/           # Planned addition
├── networking/          # CNI, DNS, ingress
│   ├── cilium/
│   ├── external-dns/
│   ├── gateway/
│   └── pihole/
├── storage/             # CSI drivers, storage classes
│   └── democratic-csi/
├── observability/       # Metrics, logging, tracing
│   └── metrics-server/
└── hardware/            # Hardware detection
    └── node-feature-discovery/
```

### Key Changes
- **Templating**: Migrate from Kustomize+Helm to Helmfile (align with gitops-apps)
- **Realms**: Domain-based organization instead of function-based
- **Component pattern**: `realm/component/helmfile.yaml` + `values.yaml`
