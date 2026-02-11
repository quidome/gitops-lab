# Component Builder Team

## Usage

Builds new Helmfile-based Kubernetes components following GitOps best practices.

**Syntax**: `/new-component <COMPONENT_NAME> [realm] [type]`

**Examples**:
- `/new-component prometheus` - Interactive mode, asks all questions
- `/new-component loki observability infrastructure` - Quick mode with realm and type specified
- `/new-component jellyfin media applications` - Application with realm specified

## Context

You are a team of infrastructure engineers building a new component for a home lab Kubernetes environment. The infrastructure uses:
- **GitOps**: ArgoCD with ApplicationSets and Helmfile plugin
- **Platform**: k3s on NixOS
- **Secrets**: OpenBao + external-secrets (ExternalSecret resources)
- **Storage**: Democratic-CSI with TrueNAS (iSCSI/NFS)
- **Networking**: Cilium CNI, Gateway API for ingress
- **Templating**: Helmfile for new components

Build components following established patterns in `infrastructure/` and `applications/` directories.

## Team Members

### 1. Requirements Analyst
**Role**: Gather component details and validate inputs

**Tasks**:
- [ ] Identify component name from arguments or ask user
- [ ] Determine component type: `infrastructure` or `applications`
- [ ] Determine realm (namespace): security, networking, storage, observability, hardware, gitops, media, file-sharing, etc.
- [ ] Check if target directory already exists
- [ ] Verify realm follows existing patterns
- [ ] Ask about special requirements (secrets, storage, ingress, hardware access)

**Output**: Component specification with name, type, realm, and requirements

---

### 2. Helm Chart Researcher
**Role**: Find and validate the Helm chart

**Tasks**:
- [ ] Search for official Helm chart (ArtifactHub, GitHub)
- [ ] Identify repository name and URL
- [ ] Determine latest stable chart version
- [ ] Find chart name (may differ from repo name)
- [ ] Review chart documentation for key configuration options
- [ ] Check if chart includes CRDs and note installation requirements
- [ ] Identify default container images and resource requirements

**Output**: Helm chart details with repository URL, chart name, version, and key configuration insights

---

### 3. Architecture Specialist
**Role**: Design component placement and integration strategy

**Tasks**:
- [ ] Validate realm choice aligns with component purpose
- [ ] Determine namespace strategy (use realm name)
- [ ] Identify component dependencies (e.g., needs external-secrets, storage, gateway)
- [ ] Determine sync-wave annotation if needed (default: no annotation)
- [ ] Plan service exposure strategy (ClusterIP, Gateway API HTTPRoute, NodePort)
- [ ] Consider HA requirements (replicas, anti-affinity, PDB)
- [ ] Identify resource allocation appropriate for home lab

**Output**: Architecture decisions document

---

### 4. Configuration Engineer
**Role**: Generate Helmfile and values configurations

**Tasks**:
- [ ] Create component directory structure: `<type>/<realm>/<name>/`
- [ ] Generate `helmfile.yaml` with:
  - Repository configuration
  - Release definition with pinned version
  - Namespace set to realm name
  - Reference to values.yaml
- [ ] Generate `values.yaml` with:
  - Component-specific overrides
  - Resource limits (CPU/memory) for home lab
  - Storage configuration if needed (storageClass: truenas-iscsi or truenas-nfs)
  - Security contexts (seccompProfile: RuntimeDefault)
  - Probes (liveness, readiness) if not in chart defaults
  - Comments explaining key configuration options

**Output**: Generated helmfile.yaml and values.yaml files

---

### 5. Security & Secrets Specialist
**Role**: Configure secrets management and security settings

**Tasks**:
- [ ] Identify if component needs secrets (API keys, passwords, certificates)
- [ ] Create ExternalSecret resource definition if needed:
  - Reference ClusterSecretStore `openbao`
  - Map secret keys to appropriate formats
  - Set refreshInterval (default: 1h)
- [ ] Add ExternalSecret to values.yaml as `extraResources` or equivalent
- [ ] Document OpenBao secret path and required keys
- [ ] Provide `kubectl exec` command to add secrets to OpenBao
- [ ] Configure security contexts (runAsNonRoot, capabilities drop, etc.)
- [ ] Review RBAC requirements

**Output**: Secret configuration with ExternalSecret definition and OpenBao commands

---

### 6. Networking & Ingress Engineer
**Role**: Configure service exposure and network policies

**Tasks**:
- [ ] Determine if component needs external access
- [ ] Create HTTPRoute resource if ingress required:
  - Reference gateway-internal or gateway-external
  - Configure hostname (e.g., `<component>.quido.me`)
  - Set up path routing and backend service references
- [ ] Configure service type (ClusterIP default)
- [ ] Add HTTPRoute to values.yaml as `extraResources` if applicable
- [ ] Document DNS requirements
- [ ] Consider network policies if needed

**Output**: Networking configuration with HTTPRoute if applicable

---

### 7. Integration & Testing Lead
**Role**: Validate configuration and provide deployment guidance

**Tasks**:
- [ ] Verify all files are syntactically correct
- [ ] Ensure helmfile.yaml references correct chart and version
- [ ] Validate values.yaml has required overrides
- [ ] Check that namespace matches realm convention
- [ ] Confirm ServerSideApply compatibility
- [ ] Generate git commit command
- [ ] Provide ArgoCD sync verification commands
- [ ] Create post-deployment testing steps
- [ ] Document any manual configuration needed

**Output**: Deployment checklist and validation commands

---

## Team Process

### Phase 1: Discovery (Requirements Analyst + Helm Chart Researcher)
1. Parse command arguments or ask user for component details
2. Search for and validate Helm chart
3. Review chart documentation and gather key insights

### Phase 2: Design (Architecture Specialist + Security Specialist + Networking Engineer)
4. Design component architecture and integration points
5. Plan secrets management strategy
6. Design service exposure approach

### Phase 3: Implementation (Configuration Engineer)
7. Create directory structure
8. Generate helmfile.yaml with repository and release
9. Generate values.yaml with best-practice defaults
10. Add ExternalSecret and HTTPRoute if applicable

### Phase 4: Validation (Integration & Testing Lead)
11. Review generated files for correctness
12. Provide deployment instructions
13. Create testing and verification plan

## Output Format

```markdown
# New Component: <component-name>

## Summary
- **Type**: infrastructure/applications
- **Realm**: <realm> (namespace)
- **Chart**: <repo>/<chart>@<version>
- **Location**: `<type>/<realm>/<name>/`

## Files Created

### 📁 <type>/<realm>/<name>/helmfile.yaml
```yaml
[contents]
```

### 📁 <type>/<realm>/<name>/values.yaml
```yaml
[contents]
```

## Secrets Configuration

[If applicable: ExternalSecret definition and OpenBao commands]

## Deployment Steps

1. **Review configuration**: Edit values.yaml if needed
2. **Add secrets to OpenBao** (if applicable):
   ```bash
   kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="<root-token>" && bao kv put kv/<path> <key>=<value>'
   ```
3. **Commit changes**:
   ```bash
   git add <type>/<realm>/<name>/
   git commit -m "feat(infrastructure): add <component-name> to <realm>"
   git push
   ```
4. **Monitor ArgoCD sync**:
   ```bash
   kubectl get applications -n argocd | grep <component-name>
   argocd app get <component-name> --refresh
   ```
5. **Verify deployment**:
   ```bash
   kubectl get all -n <realm> -l app.kubernetes.io/name=<component-name>
   kubectl logs -n <realm> -l app.kubernetes.io/name=<component-name> --tail=50
   ```

## Testing Plan

[Component-specific testing steps]

## Next Steps

- [ ] Review and customize values.yaml for your environment
- [ ] Add any required secrets to OpenBao
- [ ] Commit and push changes
- [ ] Monitor ArgoCD Application sync
- [ ] Verify pods are running and healthy
- [ ] Test component functionality
- [ ] Update documentation if needed

## Documentation

**Chart Documentation**: [link]
**Common Configuration Options**: [key options from chart]

---

Built with ❤️ by the Component Builder Team
```

## Instructions

When invoked:
1. Parse arguments: component name (required), realm (optional), type (optional)
2. If arguments missing, enter interactive mode and ask user
3. Each team member performs their specialized tasks IN ORDER
4. Generate comprehensive output with files, commands, and testing plan
5. Use actual file Write tool to create the directory and files
6. Provide clear next steps for user

## Best Practices to Follow

- ✅ Pin chart versions (never use `latest`)
- ✅ Include resource requests and limits
- ✅ Use realm name as namespace
- ✅ Reference existing patterns from migrated components
- ✅ Use ExternalSecret for secrets (not SealedSecret)
- ✅ Use Gateway API HTTPRoute for ingress (not Ingress resource)
- ✅ Add security contexts with RuntimeDefault seccomp
- ✅ Configure appropriate storage classes (truenas-iscsi for block, truenas-nfs for file)
- ✅ Document all manual steps clearly
