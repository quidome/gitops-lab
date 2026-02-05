# AGENTS.md

This document provides guidance for agentic coding assistants working with this GitOps repository. This is a k3s home lab setup managed via ArgoCD with Kubernetes manifests, Kustomize configurations, Helm charts, and Helmfile.

## ArgoCD Config Management Plugins

This repository uses ArgoCD with the following Config Management Plugins (CMPs):

1. **kustomize-build-with-helm** - Native Kustomize with Helm chart support
   - Discovers: Any directory with `kustomization.yaml`
   - Command: `kustomize build --enable-helm`

2. **helmfile** - Helmfile support for declarative Helm deployments
   - Image: `ghcr.io/helmfile/helmfile:v0.169.1`
   - Discovers: Any directory with `helmfile.yaml`
   - Init: `helmfile repos` (syncs Helm repositories)
   - Generate: `helmfile template --include-crds`

## Repository Structure

```
/home/quidome/dev/github.com/quidome/gitops-lab/
├── applications/           # User-facing applications managed by ArgoCD
│   ├── applicationset.yaml
│   ├── syncthing/
│   └── zigbee2mqtt/
├── infrastructure/        # Cluster infrastructure and controllers
│   ├── applicationset.yaml
│   ├── controllers/
│   │   ├── argocd/
│   │   ├── cert-manager/
│   │   ├── cilium/
│   │   ├── sealed-secrets/
│   │   └── ...
│   └── networking/
├── manual/                # Documentation and manual guides
└── readme.md
```

## Build, Lint, and Validation Commands

### YAML Validation

```bash
# Validate YAML syntax
find . -name "*.yaml" -o -name "*.yml" | xargs -I {} yamllint {}

# Quick syntax check with Python
python3 -c "import yaml; import sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" *.yaml

# Check for duplicate keys
python3 -c "import yaml; import sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" 2>&1 | grep -i duplicate
```

### Kubernetes Resource Validation

```bash
# Validate Kubernetes manifests (requires kubectl)
kubectl apply --dry-run=server -f <file>.yaml

# Validate with kubeval (if installed)
kubeval --strict -d .

# Check resource naming conventions
# Must be lowercase, alphanumeric, '-' separators, max 253 characters
```

### Kustomize Validation

```bash
# Validate kustomization files
kubectl kustomize <directory>/

# Build and preview kustomize overlays
kubectl kustomize infrastructure/controllers/argocd/

# Dry-run kustomize builds
kubectl kustomize --enable-helm infrastructure/controllers/argocd/ | kubectl apply --dry-run=server -f -
```

### Helm Chart Validation

```bash
# Lint Helm charts
helm lint <chart-path>

# Template Helm charts for validation
helm template <release-name> <chart-path> --namespace <ns> --values <values-file>

# Dry-run Helm installs
helm install <release-name> <chart-path> --dry-run --namespace <ns>
```

### Helmfile Validation

```bash
# Validate helmfile syntax
helmfile lint

# Template helmfile (dry-run)
helmfile template --include-crds

# List releases defined in helmfile
helmfile list

# Template with specific environment
helmfile --environment <env> template
```

### ArgoCD-Specific Validation

```bash
# Validate ArgoCD Application resources
kubectl apply --dry-run=server -f applications/applicationset.yaml

# Check ApplicationSet syntax
argocd appset validate applications/applicationset.yaml

# Sync wave annotations check
# Ensure argocd.argoproj.io/sync-wave annotations are integers
```

### Full Validation Pipeline

```bash
# Run all validations
find . -name "*.yaml" -exec yamllint {} \; && \
  find . -name "kustomization.yaml" -exec sh -c 'kubectl kustomize "$(dirname {})" > /dev/null 2>&1' \; && \
  echo "All validations passed"
```

## Code Style Guidelines

### YAML Formatting

- Use **2-space indentation** for all YAML files
- **Alphabetize keys** within resources for consistency
- Use **hyphen-case** for all keys (e.g., `serviceName`, not `service_name`)
- Remove trailing whitespace
- Use `---` document separators for multi-document files
- Keep line length under 150 characters where reasonable

### Kubernetes Resource Standards

**Naming Conventions:**
- `metadata.name`: lowercase with hyphens, max 63 characters for most resources
- `metadata.namespace`: lowercase with hyphens
- `metadata.labels`: camelCase or hyphen-case (choose one per repository)
- `kind`: PascalCase (e.g., `Deployment`, `ConfigMap`)

**Recommended Labels:**
```yaml
metadata:
  labels:
    app.kubernetes.io/name: <app-name>
    app.kubernetes.io/instance: <release-name>
    app.kubernetes.io/version: <version>
    app.kubernetes.io/component: <component>
    app.kubernetes.io/part-of: <app-name>
```

**Common Annotations:**
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-10"  # Negative for infrastructure, positive for apps
    kubectl.kubernetes.io/last-applied-configuration: ...
```

### Kustomization Files

- Always use `apiVersion: kustomize.config.k8s.io/v1beta1`
- Place `resources` before `helmCharts`
- Use `commonAnnotations` for sync-wave markers
- Set `generatorOptions.disableNameSuffixHash: true` for consistency
- Use explicit `namespace` declarations
- Prefer `valuesFile` over inline `values`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ns.yaml
  - resource.yaml

helmCharts:
  - name: <chart-name>
    repo: <helm-repo-url>
    version: <semver>
    releaseName: <release-name>
    namespace: <namespace>
    valuesFile: values.yaml

commonAnnotations:
  argocd.argoproj.io/sync-wave: "-10"
```

### Helm Values Files

- Use **2-space indentation**
- Include comments for non-obvious values
- Group related configurations
- Use descriptive key names
- Reference `values.yaml` files from Helm charts for baseline configurations

### ArgoCD ApplicationSets

- Use `git` generator for directory-based application discovery
- Set appropriate sync waves for dependency ordering
- Configure retry backoff for resilience
- Use `ServerSideApply` for large resources
- Prefer `Replace=false` unless necessary
- Include `RespectIgnoreDifferences=true` for resources managed outside ArgoCD

### Sealed Secrets

- Create plain secrets first, then seal them
- Never commit unsealed secrets to the repository
- Use the workflow documented in `manual/readme.md`
- Sealed secrets are namespace-scoped by default

```bash
# Create sealed secret
kubectl create secret generic <name> --from-file=<key>=<file> -n <namespace> | \
  kubeseal --controller-namespace kube-system --controller-name sealed-secrets -o yaml
```

### Secrets Management

- Never commit plain secrets to version control
- Use SealedSecrets for cluster-internal secrets
- Use External Secrets Operator or similar for external secrets
- Document secret creation procedures in `manual/` directory
- Reference secrets via `secretKeyRef` in pod specs

## GitOps Workflow

1. **Create/Modify Resources**: Edit YAML files in appropriate directories
2. **Validate**: Run validation commands before committing
3. **Commit**: Use conventional commit messages
4. **Push**: Changes sync automatically via ArgoCD
5. **Verify**: Check ArgoCD UI or `argocd app get` for sync status

### Sync Wave Order

- `-20` to `-10`: CSI drivers, core networking (Cilium)
- `-10`: Cluster-wide controllers (cert-manager, sealed-secrets, NFD)
- `0`: Gateways, core services (CoreDNS)
- `1+`: User applications
- Higher values for dependent applications

### ArgoCD Plugin Configuration

This repository uses `kustomize-build-with-helm` plugin for ApplicationSets. Ensure:
- Helm charts are properly referenced in kustomization files
- `valuesFile` points to the correct values.yaml
- Namespace exists before Helm releases are installed

## Common Tasks

### Adding a New Application

1. Create directory in `applications/<app-name>/`
2. Add `kustomization.yaml` with Helm chart reference
3. Add `values.yaml` with application configuration
4. Optionally add `http-route.yaml` for ingress
5. Commit and push - ArgoCD auto-discovers via ApplicationSet

### Updating a Helm Chart Version

1. Edit `kustomization.yaml` in the application's directory
2. Update `version:` field under `helmCharts:`
3. Test with `helm repo update && helm search <chart-name>`
4. Commit with message like `chore(deps): update <chart-name> to v<x.y.z>`

### Modifying Infrastructure Controllers

1. Edit files in `infrastructure/controllers/<controller>/`
2. Run `kubectl kustomize` to preview changes
3. Commit with message like `feat(infrastructure): update <controller> config`
4. Verify sync in ArgoCD after push

### Adding Application with Helmfile

1. Create directory in `applications/<app-name>/` or `infrastructure/<category>/<component>/`
2. Add `helmfile.yaml` with release definitions
3. Optionally add `values.yaml` files referenced by helmfile
4. Commit and push - ArgoCD auto-discovers via ApplicationSet

**Example helmfile.yaml:**
```yaml
repositories:
  - name: <repo-name>
    url: <helm-repo-url>

releases:
  - name: <release-name>
    namespace: <namespace>
    chart: <repo-name>/<chart-name>
    version: <version>
    values:
      - values.yaml
```

## Testing Checklist

Before committing changes:

- [ ] YAML syntax is valid (yamllint)
- [ ] Kustomize builds successfully (`kubectl kustomize`)
- [ ] Kubernetes resources pass dry-run validation
- [ ] No plain secrets committed
- [ ] Labels and annotations follow conventions
- [ ] Sync waves are appropriate for dependency ordering
- [ ] Namespace declarations are consistent
- [ ] Helm chart versions are pinned (no `latest`)

## Tooling Recommendations

- **YAML Linter**: `yamllint` - Install via `pip install yamllint`
- **K9s**: Terminal UI for Kubernetes - `brew install derailed/k9s/k9s`
- **kubectl plugins**: `krew` for plugin management
- **ArgoCD CLI**: For direct CLI interaction with ArgoCD
- **Helm**: Required for Helm chart templating
- **yq**: YAML processor for querying/modifying YAML files

## Notes for Agents

- This is a **GitOps repository** - all changes should flow through git
- No direct `kubectl apply` in normal workflow
- Always use sync-wave annotations for ordering dependencies
- Validate changes before committing
- Use sealed secrets for sensitive data
- Respect the infrastructure/applications split in directory structure
