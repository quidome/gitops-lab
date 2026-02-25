# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

GitOps-managed home lab Kubernetes infrastructure running on k3s with NixOS. Uses ArgoCD for continuous deployment with Helmfile for templating.

## Architecture

### Directory Structure

- **infrastructure/** - Helmfile-based infrastructure (gitops, security, networking, storage, observability, hardware realms)
- **applications/** - Active user applications deployed via Helmfile (file-sharing/syncthing, home-automation/mosquitto, home-automation/saic-mqtt-gateway, home-automation/hass, home-automation/zigbee2mqtt)
- **manual/** - Work-in-progress configurations not yet automated

### Technology Stack

- **Kubernetes**: k3s on NixOS
- **Networking**: Cilium (kube-proxy replacement), Gateway API, External DNS, Pi-hole
- **GitOps**: ArgoCD with ApplicationSets
- **Templating**: Helmfile with Vals for secret injection
- **Storage**: Democratic-CSI with TrueNAS (iSCSI and NFS backends)
- **Secrets**: Vault with Vals (deploy-time injection)
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

**Local minimal charts for simple exporters:**
For simple exporters (Deployment + Service + ServiceMonitor), prefer local minimal Helm charts over third-party dependencies:

- Full control over configuration and labels
- No external chart dependencies to maintain
- Consistent with GitOps maturity principles
- Example: `infrastructure/observability/proxmox-exporter/`

Use local charts when:

- Exporter has simple deployment requirements (single Deployment + Service)
- Third-party charts lack features or have uncertain maintenance
- Full control needed for GitOps workflows (Vals injection, custom labels)

Use upstream charts when:

- Complex applications with many resources
- Well-maintained charts with active community
- Chart provides significant value (CRDs, operators, complex templating)

### GitOps Deployment

- Infrastructure and applications use ApplicationSet with Helmfile plugin (`infrastructure/*/*`, `applications/*/*`)
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

### Utility Scripts

```bash
# List all resources in a namespace
python list_namespace_resources.py <namespace> [--json]

# Remove stuck namespace finalizers
./remove-namespace-finalizers.sh <namespace>
```

## Key Conventions

- **Namespace per realm**: Components use the realm name as namespace (e.g., `security`, `hardware`, `home-automation`), created automatically via `CreateNamespace=true`
- **Sync-wave annotations**: Control deployment order via `argocd.argoproj.io/sync-wave`
- **Resource configuration**: All components must define resources following this pattern:
  - **CPU**: Only requests, no limits (allows bursting)
  - **Memory**: Requests and limits must be equal (prevents OOM issues)
  - Example:
    ```yaml
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 256Mi
    ```
- **Retain policy**: Storage classes use Retain policy to preserve PVs on deletion

## Migration (Complete)

Migration from Kustomize+Helm to Helmfile-based infrastructure with domain-based realms is complete. All infrastructure and applications now use Helmfile.

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
    ├── saic-mqtt-gateway/ ✓ deployed (custom helm chart)
    └── zigbee2mqtt/       ✓ deployed (Zigbee coordinator)
```

### Secret Management

**Current approach: Vault + Vals**

- All secrets injected at deploy-time via Vals
- Secrets fetched during ArgoCD sync
- To refresh: `argocd app sync <app-name>`

#### Secret Injection with Vals

```yaml
# helmfile.yaml.gotmpl
releases:
  - name: my-app
    values:
      - secretValue:
          { { fetchSecretValue "ref+vault://kv/realm/app#KEY" | quote } }
```

See `infrastructure/security/vault/VALS-SETUP.md` for Vals configuration.

#### Secret Naming Convention

Secrets are stored as one path per application with key-value pairs inside:

```
kv/<realm>/<application>
```

- **Path segments** use lowercase-kebab-case, matching the realm (namespace) and application name
- **Keys** match their target usage: uppercase for env vars (e.g. `SAIC_USER`), lowercase-kebab for other values (e.g. `passwordfile`, `api-token`)

**Vault paths:**
| Vault Path | Keys | Application |
|---|---|---|
| `kv/home-automation/mosquitto` | `passwordfile` | mosquitto |
| `kv/home-automation/saic-mqtt-gateway` | `SAIC_USER`, `SAIC_PASSWORD`, etc. | saic-mqtt-gateway |
| `kv/networking/external-dns` | `EXTERNAL_DNS_PIHOLE_PASSWORD` | external-dns |
| `kv/security/cert-manager` | `api-token`, `email` | cert-manager |
| `kv/storage/democratic-csi-iscsi` | `driver-config-file.yaml` | democratic-csi |
| `kv/storage/democratic-csi-nfs` | `driver-config-file.yaml` | democratic-csi |
| `kv/home-automation/zigbee2mqtt` | `secret.yaml` | zigbee2mqtt |
