# Implementation Tasks: Move GitOps Repositories from Codeberg to GitHub

Based on: the repository-migration requirements discussed in this conversation.

## Relevant Files

- `infrastructure/gitops/argocd/resources/templates/managed-apps.yaml` - ArgoCD multi-source Application that currently loads `gitops-lab` and `gitops-apps` from Codeberg.
- `infrastructure/gitops/argocd/resources/templates/repo-creds-codeberg.yaml` - Current ArgoCD repository-credential template to retain temporarily and later remove or replace.
- `infrastructure/gitops/argocd/resources/templates/repo-creds-github.yaml` - Potential new GitHub repository-credential template for private repositories.
- `infrastructure/gitops/argocd/values.yaml` - Vault-backed repository credential URL and references.
- `applications/applicationset.yaml` - ApplicationSet generator and application source references for `gitops-lab`.
- `infrastructure/applicationset.yaml` - Infrastructure ApplicationSet generator and application source references for `gitops-lab`.
- `../gitops-apps/applications/applicationset.yaml` - ApplicationSet generator and application source references for `gitops-apps`.
- `infrastructure/gitops/renovate/helmfile.yaml.gotmpl` - Vault-backed Renovate credential references.
- `infrastructure/gitops/renovate/helm-chart/values.yaml` - Renovate Forgejo/Codeberg platform and endpoint configuration.
- `infrastructure/gitops/renovate/secret.example.yaml` - Renovate credential documentation and example values.
- `manual/argocd/renovate-application.yaml` - Legacy/manual ArgoCD source reference, if still used.
- `README.md`, `../gitops-apps/README.md`, and component documentation - Migration, credential, and recovery instructions that may need updating.
- `tasks/tasks-codeberg-to-github-migration.md` - This implementation checklist.

### Notes

- This task list covers a new repository-migration feature and is intentionally separate from the Kubernetes SSO task list.
- Assumption: the GitHub repositories retain the names `quidome/gitops-lab` and `quidome/gitops-apps`, use the `main` branch, and preserve the existing directory layout.
- The repositories may be public or private; the implementation must confirm this and choose anonymous access or a read-only GitHub credential accordingly.
- No application unit tests are expected. Validation should use YAML, Helmfile, ArgoCD, and read-only Kubernetes checks already used by this repository.
- Do not commit tokens, rendered Vault values, or other secret material.
- Do not delete the Codeberg repositories until the GitHub sources and credentials have been verified in the live cluster.

## Instructions for Completing Tasks

As tasks are completed, check them off by changing `- [ ]` to `- [x]`. Update the file after each subtask, not only after an entire parent task.

## Acceptance Criteria

- Both repositories are available on GitHub with the `main` branch and the directory layout expected by the existing ApplicationSets.
- ArgoCD can authenticate to the GitHub repositories when they are private, or successfully fetches them anonymously when they are public.
- `argocd-managed-apps`, the infrastructure ApplicationSet, the application ApplicationSet, and the `gitops-apps` ApplicationSet all use the correct GitHub repository URLs.
- Generated Applications remain healthy and synchronized, with no unintended workload deletion or recreation.
- Renovate uses the GitHub platform when it is enabled, and no active ArgoCD configuration depends on Codeberg.
- Codeberg credentials and references are removed only after the GitHub cutover has been verified and the rollback window has ended.

## Tasks

- [ ] 0.0 Create feature branch
  - [ ] 0.1 Create and checkout `feat/migrate-codeberg-to-github` without modifying or combining it with the Kubernetes SSO work.

- [ ] 1.0 Inventory all active Codeberg dependencies and establish the migration baseline
  - [ ] 1.1 Confirm the current branch, revision, and working-tree status in both the `gitops-lab` and sibling `gitops-apps` repositories; preserve unrelated local changes.
  - [ ] 1.2 Enumerate every Codeberg URL in active ArgoCD manifests, including the two sources in `managed-apps.yaml`, both `gitops-lab` ApplicationSets, and the `gitops-apps` ApplicationSet.
  - [ ] 1.3 Determine whether `manual/argocd/renovate-application.yaml` is applied anywhere; classify it as active or legacy before changing it.
  - [ ] 1.4 Inspect the live `gitops` namespace read-only and record the current status of `argocd-managed-apps`, ApplicationSets, generated Applications, and the `repo-creds-codeberg` Secret without exposing secret data.
  - [ ] 1.5 Record the intended GitHub owner, repository names, branch, visibility, authentication method, and rollback source URLs.

- [ ] 2.0 Create and verify the GitHub repositories, branch, contents, visibility, and access model
  - [ ] 2.1 Create or migrate `quidome/gitops-lab` and `quidome/gitops-apps` on GitHub while preserving the `main` branch and all paths consumed by ArgoCD.
  - [ ] 2.2 Confirm the GitHub copies contain the required ApplicationSets, Helmfile directories, and multi-source manifest before changing the live ArgoCD source.
  - [ ] 2.3 Configure repository visibility and branch permissions according to the selected public or private access model; do not put credentials in either repository.
  - [ ] 2.4 Verify the exact HTTPS Git URLs and that both repositories can be resolved from the ArgoCD repository-server and ApplicationSet-controller network path.
  - [ ] 2.5 Prepare a rollback copy or documented Codeberg revision so the source can be restored if the cutover fails.

- [ ] 3.0 Prepare GitHub credentials in Vault and ArgoCD without interrupting Codeberg access
  - [ ] 3.1 Decide whether anonymous GitHub access is sufficient; for private repositories, create a dedicated GitHub read-only credential with access to both repositories.
  - [ ] 3.2 Store the GitHub username/token or selected GitHub App/deploy-key material in Vault using a new, clearly named credential entry; never commit the secret value.
  - [ ] 3.3 Add a GitHub repository-credential template, such as `repo-creds-github`, with a URL prefix matching `https://github.com/quidome` while retaining the Codeberg credential temporarily.
  - [ ] 3.4 Render or sync the ArgoCD Helmfile resources and verify that the GitHub credential Secret exists in namespace `gitops` without printing its data.
  - [ ] 3.5 Test repository authentication through ArgoCD before changing any source URL and record the result for rollback purposes.

- [ ] 4.0 Update the ArgoCD multi-source Application and both repositories' ApplicationSets to use GitHub
  - [ ] 4.1 Replace the `gitops-lab` URLs in `infrastructure/gitops/argocd/resources/templates/managed-apps.yaml`, `applications/applicationset.yaml`, and `infrastructure/applicationset.yaml`.
  - [ ] 4.2 Replace the `gitops-apps` URLs in `managed-apps.yaml` and `../gitops-apps/applications/applicationset.yaml`.
  - [ ] 4.3 Preserve `main`, all paths, directory include patterns, plugin configuration, destinations, namespaces, and sync policies.
  - [ ] 4.4 Ensure the GitHub copies contain the updated ApplicationSet references before changing the controlling `argocd-managed-apps` source on the currently active Codeberg revision.
  - [ ] 4.5 Validate the changed YAML and rendered ArgoCD resources, checking that both multi-source entries and every generator/template `repoURL` point to the intended GitHub repository.
  - [ ] 4.6 Commit the migration changes atomically in each repository and push them in an order that leaves the GitHub revisions ready before ArgoCD switches away from Codeberg.

- [ ] 5.0 Migrate the Renovate platform configuration and any remaining active Codeberg integrations
  - [ ] 5.1 Update `infrastructure/gitops/renovate/helm-chart/values.yaml` from the Forgejo platform and Codeberg API endpoint to GitHub, removing the endpoint when the default GitHub API endpoint is sufficient.
  - [ ] 5.2 Confirm the Renovate repository list still names `quidome/gitops-lab` and `quidome/gitops-apps`, and provide a separate GitHub token with the write permissions Renovate requires if applicable.
  - [ ] 5.3 Update the Renovate Helmfile/Vault references and example-secret comments without committing token values.
  - [ ] 5.4 Update the manual Renovate Application source only if task 1 confirms it remains active.
  - [ ] 5.5 Search both repositories again for active Codeberg URLs and classify any remaining matches as intentional documentation, legacy configuration, or a migration defect.

- [ ] 6.0 Execute and validate the staged ArgoCD cutover, including generated Applications and workloads
  - [ ] 6.1 Allow ArgoCD to reconcile the updated `argocd-managed-apps` Application and confirm both GitHub sources are fetched successfully.
  - [ ] 6.2 Confirm the infrastructure and applications ApplicationSets remain present, healthy, and generating the expected Applications from GitHub.
  - [ ] 6.3 Inspect generated Application source URLs and revisions; verify that no active generated Application still points to Codeberg.
  - [ ] 6.4 Check ArgoCD repository-server and ApplicationSet-controller events/logs for authentication, repository, revision, path, plugin, or manifest-generation errors.
  - [ ] 6.5 Verify representative infrastructure and application workloads remain healthy and that the migration caused no unintended pruning, namespace deletion, or persistent-volume disruption.
  - [ ] 6.6 Trigger or observe a normal ArgoCD refresh and confirm a GitHub commit is detected without requiring a manual reinstallation or workload redeployment.
  - [ ] 6.7 If Renovate is active, verify that its next job can authenticate to GitHub and process both repositories using the intended token.

- [ ] 7.0 Remove obsolete Codeberg credentials and references, update documentation, and record rollback/recovery steps
  - [ ] 7.1 After the cutover is healthy, remove the Codeberg credential template, values, and Secret through the normal GitOps flow; do not delete the GitHub credential.
  - [ ] 7.2 Remove or update remaining active Codeberg references and rename Codeberg-specific resource names where appropriate, while preserving any historical documentation references that are intentionally retained.
  - [ ] 7.3 Update `README.md`, repository documentation, and the sibling `gitops-apps` documentation with the GitHub URLs, credential setup, migration order, validation commands, and rollback procedure.
  - [ ] 7.4 Update local Git remotes and any external GitHub/ArgoCD integration settings that are outside the repository, such as webhooks or deploy keys, if used.
  - [ ] 7.5 Perform a final read-only cluster check and repository search, then record the final GitHub revisions and the date after which Codeberg can safely be archived or deleted.
