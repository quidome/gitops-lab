# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

GitOps-managed home lab Kubernetes infrastructure running on k3s with NixOS. Uses ArgoCD for continuous deployment with Helmfile (new) and Kustomize+Helm (legacy) for templating.

## Architecture

### Directory Structure
- **infrastructure/** - Helmfile-based infrastructure (gitops, security, networking, storage, observability, hardware realms)
- **applications/** - Active user applications deployed via Helmfile (file-sharing/syncthing, home-automation/mosquitto, home-automation/saic-mqtt-gateway, home-automation/hass)
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
├── values.yaml          # Helm value overrides
└── resources/           # Extra manifests (ExternalSecrets, HTTPRoutes, etc.)
```

**Custom Helm charts (when more control is needed):**
```
realm/component/
├── helmfile.yaml.gotmpl # Helmfile with templating
└── helm-chart/          # Local Helm chart
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
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
  -f infrastructure/kube-system/cilium/values.yaml \
  --version 1.17.6 --set operator.replicas=1

# ArgoCD
kubectl create namespace argocd
helmfile -f infrastructure/gitops/argocd/helmfile.yaml apply
kubectl apply -f infrastructure/applicationset.yaml
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

- **Namespace per realm**: New Helmfile components use the realm name as namespace (e.g., `security`, `hardware`), created automatically via `CreateNamespace=true`. Legacy components define namespaces in `ns.yaml`
- **Sync-wave annotations**: Control deployment order via `argocd.argoproj.io/sync-wave`
- **Resource limits**: All components should define CPU/memory requests and limits
- **Retain policy**: Storage classes use Retain policy to preserve PVs on deletion

## Infrastructure Migration (Complete)

Migration from Kustomize+Helm to Helmfile-based infrastructure with domain-based realms is complete. All components now use Helmfile.

### Migration Status

**Migrated to `infrastructure/` (Helmfile):**
- `gitops/argocd` — GitOps controller
- `security/openbao` — Secret management (OpenBAO)
- `security/external-secrets` — External Secrets Operator
- `security/cert-manager` — Certificate management
- `security/vault` — HashiCorp Vault for Vals integration
- `kube-system/cilium` — CNI and kube-proxy replacement
- `networking/gateway` — Gateway API resources
- `democratic-csi/democratic-csi` — iSCSI and NFS storage drivers
- `observability/metrics-server` — Metrics server
- `hardware/node-feature-discovery` — Hardware detection


### Current Structure
```
infrastructure/
├── gitops/              # Deployment automation
│   └── argocd/            ✓ migrated
├── security/            # Secrets, certs, access control
│   ├── cert-manager/      ✓ migrated
│   ├── external-secrets/  ✓ migrated
│   ├── openbao/           ✓ migrated
│   └── vault/             ✓ migrated
├── kube-system/         # Core cluster components
│   └── cilium/            ✓ migrated
├── networking/          # DNS, ingress
│   ├── external-dns/      ✓ migrated
│   ├── gateway/           ✓ migrated
│   └── pihole/            ✓ migrated
├── democratic-csi/      # CSI drivers, storage classes
│   └── democratic-csi/    ✓ migrated
├── observability/       # Metrics, logging, tracing
│   └── metrics-server/    ✓ migrated
└── hardware/            # Hardware detection
    └── node-feature-discovery/  ✓ migrated

applications/
├── file-sharing/
│   └── syncthing/         ✓ deployed
└── home-automation/
    ├── hass/              ✓ deployed (Home Assistant)
    ├── mosquitto/         ✓ deployed (MQTT broker)
    └── saic-mqtt-gateway/ ✓ deployed (custom helm chart)
```

### Secret Management

**Current approach: Hybrid**
- **Vault + Vals** - Deploy-time secret injection for app-specific secrets
- **OpenBao + External Secrets** - Runtime sync for shared infrastructure secrets

#### Secret Injection Methods

**Vals (Deploy-time - Helmfile):**
```yaml
# helmfile.yaml.gotmpl
environments:
  default:
    values:
      - secrets:
          KEY: {{ fetchSecretValue "ref+vault://kv/realm/app#KEY" }}
```
- Used by: `saic-mqtt-gateway`
- Secrets fetched during ArgoCD sync
- To refresh: `argocd app sync <app-name>`

**External Secrets (Runtime - Operator):**
```yaml
# resources/external-secret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
spec:
  secretStoreRef:
    name: openbao  # or vault
    kind: ClusterSecretStore
```
- Used by: Infrastructure and shared app secrets
- Auto-syncs every 1 hour
- To refresh: Wait or delete pod

See `infrastructure/security/vault/VALS-SETUP.md` for Vals configuration.

#### Secret Naming Convention

Secrets are stored as one path per application with key-value pairs inside:
```
kv/<realm>/<application>
```

- **Path segments** use lowercase-kebab-case, matching the realm (namespace) and application name
- **Keys** match their target usage: uppercase for env vars (e.g. `SAIC_USER`), lowercase-kebab for other values (e.g. `passwordfile`, `api-token`)

**Vault paths:**
| Vault Path | Keys | Method | Application |
|---|---|---|---|
| `kv/home-automation/mosquitto` | `passwordfile` | **Vals** | mosquitto |
| `kv/home-automation/saic-mqtt-gateway` | `SAIC_USER`, `SAIC_PASSWORD`, etc. | **Vals** | saic-mqtt-gateway |
| `kv/networking/external-dns` | `EXTERNAL_DNS_PIHOLE_PASSWORD` | **Vals** | external-dns |
| `kv/security/cert-manager` | `api-token`, `email` | External Secrets | cert-manager |
| `kv/storage/democratic-csi-iscsi` | `driver-config-file.yaml` | External Secrets | democratic-csi |
| `kv/storage/democratic-csi-nfs` | `driver-config-file.yaml` | External Secrets | democratic-csi |

