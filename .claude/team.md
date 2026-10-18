# Team for gitops-lab

project-type: infrastructure    # software | infrastructure  (see project-types/)
maturity: maturing              # early | maturing | mature  (how strict the architect is)
product-docs: docs/product/     # or the user docs, for example docs/src/

## Roles
# role: persona + expertise, expertise
product-lead: carl
# product-designer: left out (infrastructure project; Discover is led by the product-lead)
architect: steve + kubernetes
engineer: bruce + kubernetes
tester: august + kubernetes
developer: matthew + kubernetes
scope-keeper: matthew

## Project notes
# Short facts every stage must know, for example the check command.
check: helmfile -f <realm>/<component>/helmfile.yaml template (render), then ArgoCD sync and app health
argocd: namespace gitops, no argocd CLI; use kubectl
rules: AGENTS.md (resources, Recreate strategy for RWO volumes, HTTPRoute defaults, Vault path naming)
