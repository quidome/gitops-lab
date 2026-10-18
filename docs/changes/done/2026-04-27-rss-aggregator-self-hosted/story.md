# Deployment: Self-Hosted RSS Aggregator

## Context

The platform needs an internal, self-hosted RSS aggregation service to replace Feedly dependency for day-to-day feed reading and synchronization. The primary user is single-user today, with optional future multi-user support if needed. The service must support iOS client usage through a compatible sync API and remain internal-only for now.

This deployment should fit existing GitOps conventions in the repository (Helmfile + ArgoCD ApplicationSet, Vault + Vals, namespace-per-realm conventions, and platform resource configuration standards).

## Deployment Stories

### Story 1: Replace Feedly with an internally hosted RSS backend

**As a** home-lab operator,  
**I want to** deploy an RSS aggregation backend in GitOps,  
**So that** I can stop depending on Feedly for feed storage and synchronization.

#### Acceptance Criteria
- [ ] RSS backend is deployed through GitOps under `applications/` and managed by ArgoCD.
- [ ] Subscriptions and read state persist across pod restarts and upgrades.
- [ ] The deployment follows platform resource conventions (CPU requests only, memory requests=limits).
- [ ] Deployment health is visible via ArgoCD and reconciliation behaves consistently with other applications.

#### Expected Behavior
- ArgoCD sync applies Helmfile-managed resources and the service becomes available internally.
- User can add RSS feeds from web UI/API and see feed entries populate.
- Service remains functional through routine reconciliations and restarts.

#### Edge Cases & Failures
- **Pod restart/crash**: data remains intact and service recovers without reconfiguration.
- **Bad release/config update**: ArgoCD marks app degraded; operator can rollback/sync retry.
- **Storage attach constraints (RWO)**: rollout strategy must prevent dual-attach failure during updates.

### Story 2: Support iOS app synchronization

**As a** mobile user,  
**I want to** connect an iOS RSS app to the self-hosted backend,  
**So that** I can read and sync feeds from my phone.

#### Acceptance Criteria
- [ ] Backend exposes a mobile-compatible API supported by at least one practical iOS app.
- [ ] API authentication works from internal network clients.
- [ ] Supported iOS app/client setup is documented for repeatable onboarding.
- [ ] Read/unread and subscription synchronization works between web and mobile clients.

#### Expected Behavior
- User configures endpoint and credentials in iOS app.
- Client can fetch subscriptions/feed items and sync read state.
- Web and mobile clients stay consistent for normal usage.

#### Edge Cases & Failures
- **Incorrect credentials**: client receives clear authentication failure.
- **API compatibility drift after upgrades**: compatibility must be validated against documented client before version changes.
- **Temporary backend outage**: client reconnects and resumes sync when service returns.

### Story 3: Keep access internal now, preserve external path later

**As a** platform operator,  
**I want to** keep RSS service internal-only initially,  
**So that** exposure risk stays low while leaving a clear path for future external access.

#### Acceptance Criteria
- [ ] Service routing is limited to internal/trusted network access.
- [ ] User authentication is required for all access.
- [ ] Design captures a future extension path for external access and stronger auth controls without restructuring everything.

#### Expected Behavior
- Service is reachable internally via platform routing/TLS patterns.
- Public DNS/public exposure is not enabled in this phase.
- Future externalization can be introduced as an incremental change.

#### Edge Cases & Failures
- **Unintended exposure**: configuration review and GitOps diffs must make external exposure obvious.
- **Future external requirement**: should not require complete chart/layout redesign.

## GitOps Structure

Proposed structure (realm name to be confirmed during implementation):

```text
applications/productivity/rss/
├── helmfile.yaml
├── values.yaml
└── resources/
    └── http-route.yaml
```

Notes:
- Helmfile manages the RSS backend release and required dependencies.
- If database is separate, it is represented in Helmfile values/releases with persistent storage.
- Additional manifests (e.g., HTTPRoute) live in `resources/` and follow existing drift-safe defaults.
- Component is discovered and deployed by existing `applications/*/*` ApplicationSet.

## Environment Strategy

- Current scope is a single home-lab production environment (no dev/staging/prod split required now).
- Internal-only access in this phase.
- Future external access and stronger auth model will be tracked as a separate enhancement story.

## Consistency Notes

- Follows existing Helmfile-based component pattern under `applications/`.
- Uses Vault + Vals for credentials and sensitive configuration.
- Adheres to platform resource conventions and ArgoCD sync/retry behavior.
- Namespace/realm naming should remain consistent with existing domain-based organization.

## Implementation Remarks

### Architecture & Security (Kai)

- RSS backend should be treated as stateful from an operational perspective (persistent app/DB state is critical).
- Internal-only deployment still requires TLS and explicit authentication.
- Namespace and network boundaries should be explicit to avoid accidental broad access.
- If RWO-backed volumes are used with Deployment, update behavior must avoid concurrent volume attachment issues.

### Operational Considerations (Jordan)

- Biggest hidden risk is client compatibility drift; the team should pin and validate one supported iOS client path.
- Secret paths should be created using existing Vault naming conventions from day one.
- Manual subscription migration is acceptable and should be explicitly in-scope; read-state migration from Feedly is out-of-scope.
- External exposure/auth hardening should be captured as a follow-up story to avoid scope creep in initial rollout.

## Open Questions

- Which RSS backend is selected as the default platform choice (e.g., Miniflux vs FreshRSS)?
- Which specific iOS app should be the documented and tested compatibility target?
- Final realm/namespace naming for this component (`productivity` or another existing realm).