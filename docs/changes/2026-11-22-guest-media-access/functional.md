# Functional spec: Guest access to media apps over Tailscale

**Status**: approved            <!-- draft | approved -->
**Change**: docs/changes/2026-11-22-guest-media-access
**Date**: 2026-11-22

## Context
The operator wants a few guests (people outside the household) to reach two media services on
the platform over the network: Jellyfin (`flix.quido.me`, to watch media) and Overseerr
(`seerr.quido.me`, to request new media). Today only devices on the home network, and household
devices on the operator's Tailscale network (a private network that runs over the internet), can
reach them.

The vision (changed 2026-11-22) allows this with a fixed rule: nothing on the platform is open to
the public internet. Over the network, guests reach only the shared services, and only through the
shared entry. The operator chooses the shared services in the platform, not in each service.

So guests connect over Tailscale. Each guest makes a free Tailscale account and accepts a share
(access to one single device of the operator's Tailscale network) from the operator. That device
is the shared entry. Through it, guests reach the shared services and nothing else.

**This change is about network access only.** What a guest may do inside a service (accounts,
logins, permissions) is not part of it. Today Overseerr logs people in with Plex accounts; that
stays as it is. Moving Overseerr to Jellyfin accounts is a separate idea in `docs/ideas.md`.

The services themselves (Jellyfin, Plex, Overseerr) and their routes are in the second, private
repository (`gitops-apps`). The shared entry and the list of shared services are in this
repository. The product document for this change is `docs/product/guest-access.md` (new).

**Serves the purpose**: the platform runs services that people use; now also for guests, without
a public way in. It also serves the lab purpose: a private way in, access limits per service, and
limits on what the shared entry can reach.

## User stories

### Story 1: A guest gets network access
**As the** operator, **I want to** give one guest network access to the shared services, **so
that** the guest can reach them from their own devices without anything public.

#### Acceptance criteria
- [ ] The operator gives access to a guest with steps in the Tailscale admin console only (no change in git, no change on the cluster).
- [ ] The guest needs only a free Tailscale account and the Tailscale app.
- [ ] After the guest accepts the share, `https://flix.quido.me` and `https://seerr.quido.me` open on the guest's device (a computer or a phone with the Tailscale app) with a valid certificate (no browser warning), and show the service's own login page.
- [ ] The Jellyfin app on a guest's phone connects to `https://flix.quido.me`.
- [ ] `http://flix.quido.me` sends the guest to the HTTPS address.
- [ ] The steps for the operator (invite a guest) and a short text for the guest (how to join) are in `docs/product/guest-access.md`. It also refers to the steps to make the guest's accounts in each service; making those steps is not in scope.

#### Behaviour
The operator sends a share invite for the shared entry to the guest. The guest makes a Tailscale
account, installs the app, accepts the share, and keeps the app on. The guest then opens the
same web addresses as the household.

#### Errors and edge cases
- The guest's Tailscale app is off: the addresses do not open (no answer). The guest text says to turn the app on.
- The guest's DNS (for example a home router with DNS rebinding protection) blocks public DNS answers that point to a private address: the names do not resolve. The guest text names this problem and a fix.
- The guest already uses Tailscale for their own network: the share is added to it, and nothing else changes for the guest.
- A device that cannot run the Tailscale app (for example many smart TVs): it cannot reach the shared services. The guest text says so.

### Story 2: Guests reach only the shared services
**As the** operator, **I want** guests to reach only the shared services, **so that** a guest
never reaches anything else on the platform or the home network.

#### Acceptance criteria
- [ ] From a guest device, only Jellyfin and Overseerr answer. Other names under `quido.me` (for example the task list, Home Assistant, Plex, Tautulli) give no content.
- [ ] From a guest device, only HTTP and HTTPS on the shared entry are reachable. Other ports and other addresses on the home network and the cluster do not answer.
- [ ] A service in the same namespace as a shared service (for example Tautulli next to Overseerr) is not reachable for guests, unless the operator adds it to the shared services.
- [ ] After this change, nothing on the platform is reachable from the public internet, checked from outside the home network. (Until 2026-11-22 the router forwarded the Plex port to the internet; the operator removed that forward on 2026-11-22. Plex's own remote access setting may still be on; that is a Plex setting, see Not in scope.)

#### Errors and edge cases
- A route for a service that is not in the list tries to use the shared entry: it is refused, and the operator can see that it was refused.

### Story 3: The operator chooses the shared services
**As the** operator, **I want to** choose in one place in the platform which services are shared
services, **so that** sharing a service is a conscious choice and not a side effect of a change
to a service.

#### Acceptance criteria
- [ ] The list of shared services is in one place in this repository, in git.
- [ ] A change in the `gitops-apps` repository alone cannot make a service reachable for guests.
- [ ] To add or remove a shared service, the operator changes that one place and the route of the service. ArgoCD applies it; no manual step on the cluster.
- [ ] `docs/product/guest-access.md` says how to add and remove a shared service.

### Story 4: The operator removes a guest's network access
**As the** operator, **I want to** remove a guest's network access, **so that** the guest no
longer reaches any shared service.

#### Acceptance criteria
- [ ] The operator removes the share in the Tailscale admin console. After that, the guest's devices get no answer from the shared services.
- [ ] `docs/product/guest-access.md` has the steps, and says that accounts inside the services are removed separately.

### Story 5: Nothing changes for the household
**As a** user, **I want** my media services to work as before, **so that** the change for guests
does not cost me anything.

#### Acceptance criteria
- [ ] At home, `flix.quido.me`, `seerr.quido.me` and `plex.quido.me` work as before.
- [ ] Away from home, household devices on the operator's Tailscale network reach the same services as before, at the same names (checked on one household device).
- [ ] The Plex apps in the household keep working at home. Away from home, they work over the operator's Tailscale network (checked on one household device). This is a change: until 2026-11-22 they could also connect through the router's port forward, which the operator removed.
- [ ] During the change, each service is unreachable for the household for a few minutes at most.

#### Errors and edge cases
- A household device that uses encrypted DNS that skips the home DNS server (DNS over HTTPS) gets the public answer and goes to the shared entry. There it reaches only the shared services. `docs/product/guest-access.md` names this.

### Story 6: The shared entry survives a restart and a rebuild
**As the** operator, **I want** the shared entry to keep its identity and its Tailscale address
after a restart, a rebuild of the entry, or a rebuild of the platform, **so that** guests do not
need a new invite and the public DNS record stays correct.

#### Acceptance criteria
- [ ] After a restart of the shared entry, guests reach the shared services without any action.
- [ ] A copy of the state of the shared entry (its identity and address) is kept outside the cluster's own storage, and a restore from that copy was done once and shown to keep the same address. Until a copy outside the platform exists, this copy is not yet a backup in the meaning of the word list; the copy outside the platform comes with the general backup work.
- [ ] Recovery steps are in `docs/product/guest-access.md`: restore the state, and what to do when the state is lost (new shares for all guests, new public DNS record).
- [ ] All manual steps outside git (the Tailscale access policy, the shares, the public DNS record) are listed in `docs/product/guest-access.md` with their current values, and the rebuild steps refer to them. The Tailscale access policy stays a manual step in this change; keeping it in git is a separate idea.

### Story 7: The operator hears when guests cannot connect
**As the** operator, **I want to** get a push message when guests cannot reach the shared
services, **so that** I know before a guest tells me.

#### Acceptance criteria
- [ ] When the shared entry is down or not connected to Tailscale for longer than 30 minutes, the operator gets an alert through the existing alert path (push message).
- [ ] When the shared services do not answer through the shared entry for longer than 30 minutes, the operator gets an alert.

## Interface
- **Guest**: the Tailscale app, a share invite link, and the web addresses `https://flix.quido.me` and `https://seerr.quido.me` (and the Jellyfin app pointed at `https://flix.quido.me`).
- **Operator, guests**: the Tailscale admin console (invite, remove).
- **Operator, shared services**: one list in this repository, for example:
  ```
  shared services: jellyfin (media-server), overseerr (media-tools)
  ```
  The exact form is decided in Design.
- **Public DNS**: one wildcard record for all names under `quido.me`, which points to the Tailscale address of the shared entry. It is the only public record that points to the platform, so public DNS does not show which services run.

## Consistency
- Same HTTPS names and the same certificate for guests and for the household (vision core value 5: a clear HTTPS name for each service).
- Routes attach to the HTTPS listener; HTTP is sent to HTTPS, as for all other routes.
- Secrets for the Tailscale connection are stored in Vault and injected at deploy time, as all other secrets.
- Services and their routes stay in `gitops-apps`; the shared base (the shared entry, the list of shared services) is in this repository, as for single sign-on.

## What changes for existing users
- Household: nothing visible (Story 5). The current external gateway changes purpose: it becomes part of the shared entry. The Plex and Overseerr routes, which use it now, change: Plex moves to the internal gateway, Overseerr stays on the shared one, and Jellyfin moves to the shared one.
- The operator: new manual steps for each guest, and new recovery steps.

## Warnings from architect and engineer
**[Steve]**
- The change is in two repositories. The order of the steps must make sure that the Plex and Overseerr routes never point to a gateway that refuses them (Story 5: short breaks only).
- The gateway of the shared entry must keep its home-network address, because the household reaches it there and the DNS for the household points to it.
- Tailscale is a third-party service. When it is down, guests have no access. This is acceptable (short outages are acceptable), but `docs/product/guest-access.md` must say it.
- Choosing per service, not per namespace, means the platform must name each shared service. That list must still be the only way to share (Story 3).
- Some parts stay outside git: the Tailscale access policy, the shares, the public DNS record. The vision allows manual work only for bootstrap and only when written down, so they must be written down (Story 6).

**[Bruce]**
- If the state of the shared entry is lost, it gets a new Tailscale address and becomes a new device. Then every guest needs a new share, and the public DNS record is wrong. This is why Story 6 needs a tested restore.
- The shared entry is a new way in. If it is broken into, it must reach nothing except the shared gateway and what it needs to work (DNS, the cluster API, Tailscale's public servers).
- The HTTP-to-HTTPS redirect of the shared gateway is a route in the `networking` namespace. The limit on shared services must not block it.
- The public DNS record covers all names under `quido.me`. Names that are not shared then point to the shared entry and must give no content (Story 2). The certificate is a wildcard, so it does not show which services exist.
- Household devices on the Tailscale network can also reach the shared entry. They must still use their current way in (the home network names), or Story 5 is not met away from home.
- The check for the second alert in Story 7 must come from outside the cluster over Tailscale, or it does not test what guests use.
- Whether the gateway passes settings to its own network Service (needed to expose it on Tailscale) is not known for the Cilium version in use (1.20.5). Design must check it.
- Not checked: Jellyfin may see guests as clients on the home network, so its limits for remote clients would not apply. A note for Design.

## Not in scope
- Accounts, logins and permissions inside the services (Jellyfin accounts, Overseerr login, Plex sharing). These stay as they are. Moving Overseerr to Jellyfin accounts is a separate idea in `docs/ideas.md`.
- Plex as a shared service (a separate idea in `docs/ideas.md`).
- Any access from the public internet (also not Tailscale Funnel or a public tunnel).
- Other shared services than Jellyfin and Overseerr.
- Changes to the household's Tailscale router `net1` other than what Story 5 needs.
- Keeping the Tailscale access policy in git (a separate idea in `docs/ideas.md`).
- The load of guest streams on Jellyfin and on the home upload link. Limits for guests (for example a streaming quality limit) are settings inside Jellyfin.
- Plex's own remote access setting and the Plex relay (settings inside Plex).
- A copy of the shared entry's state outside the platform (comes with the general backup work).

## Open questions
None. Answered on 2026-11-22: accounts and logins are out of scope; the Tailscale access policy
stays a written manual step; the alert time is 30 minutes; the wildcard is the only public record
under `quido.me` that points to the platform.

## Spec review
Review 2, 2026-11-22, fresh agent. Input: mode `spec`, this change folder; no other text was
given. Read: this file, `idea.md`, `change.md`, `docs/vision.md` (with the uncommitted diff),
`docs/language.md`, `docs/product/` (no guest-access document yet; `sso-onboarding.md` only for
the "shared base in this repository" pattern). Read-only checks in this repository and in
`../gitops-apps` are named per finding.

| Story | What the user is doing here | Verdict | Note |
|---|---|---|---|
| 1 Guest gets network access | The guest wants to watch a film (Jellyfin) or ask for one (Overseerr) from their own device; the operator wants to let them in once, with little work | serves – note | (a) Network access alone does not get the guest to their goal: they see a login page, nothing more. Story 4 says accounts are removed separately, but Story 1 does not say that accounts are made separately; the guest text and operator steps in `guest-access.md` should at least point to "now make the account in each service", or the operator's real onboarding is half written. (b) Overseerr logs in with Plex accounts; a guest who logs in there must, as far as I know, have access to the operator's Plex server through plex.tv, and the Plex app then reaches Plex outside the shared entry (direct or through the Plex relay). That would be a guest reaching a non-shared service over the network, against the vision principle. Not checked (Overseerr login rules and Plex remote-access setting not inspected). Design or the operator should state how guests log in to Overseerr today, before Story 2 can be called met. (c) Adding a guest is routine manual work outside git. The vision principle says manual work is acceptable "only for the first bootstrap"; Steve's warning reads it as "acceptable when written down". See general note G1. Checked: reading `vision.md` Principles. |
| 2 Guests reach only shared services | The operator protects the household and the platform from a new way in | serves – note | Directly serves the new vision principle. AC 4 ("nothing reachable from the public internet before or after") may already be false for Plex: its Service is a `LoadBalancer` on `172.16.40.54:32400` with `advertiseIp` set (search `type\|loadBalancer\|advertiseIp` in `gitops-apps/applications/media-server/plex/helm-chart/values.yaml`). Whether the router forwards 32400 or Plex remote access is on is not checked. If it is, Story 5 AC 3 ("Plex apps keep working away, no change") and this AC conflict; the operator must decide which wins. |
| 3 Operator chooses shared services | The operator wants sharing to be a conscious act in the platform, not a side effect | serves | Matches the vision principle word for word. Today both Overseerr and Plex attach to `gateway-external`, which allows routes from all namespaces (read `infrastructure/networking/gateway/resources/templates/gateway-external.yaml`; search `gateway-external` in `gitops-apps`), so this story closes a real gap. |
| 4 Operator removes access | The operator ends a guest's access when the friendship or need ends | serves | Clear, and honest that accounts are a separate step. |
| 5 Nothing changes for household | A household member watches or requests media as before | serves – note | Missing case: guests now share the same Jellyfin server and the home upload link. Guest streams may transcode and take bandwidth or CPU, so household playback can get worse; Bruce's untested note (Jellyfin may see guests as local clients, so remote bitrate limits do not apply) makes this more likely. "Nothing changes for the household" should say whether guest load is in or out of scope. Not checked (Jellyfin settings not inspected). |
| 6 Shared entry survives restart/rebuild | The operator keeps guests working without new invites after a failure | serves | Fits core values 1 and 4 and uses "backup" in the word-list sense correctly (a copy on the platform is named as not yet a backup). Right size for supporting work. |
| 7 Operator hears when guests cannot connect | The operator wants to know before a guest tells them | serves | Fits the vision priority on alerting and the principle that a service is not done without alerting. |

**Serves the purpose**: yes. The claim holds: it extends "services that people use" to the new
group "guests" that the vision now names, and the lab part (a private way in, limits per service)
is real. It is ahead of the vision priorities (backups, alerting); that is the operator's
recorded choice (log in `change.md`), and Stories 6 and 7 keep it in line with the first two
core values. Checked: reading `vision.md` and `change.md`.

**General notes**
- **G1 – manual routine work vs. the principle.** The vision says "Manual work is acceptable only for the first bootstrap, and it must be written down", and "Git is the truth". Inviting and removing guests (Stories 1, 4), the Tailscale access policy and the public DNS record are manual and outside git, and invites are routine, not bootstrap. The spec writes them down (Story 6), which is the second half of the principle, not the first. This does not block Design, but the vision should say it on purpose: either the Vision stage adds a one-line exception (for example "guest invites and removals are manual steps in the private-network console, written down"), or the principle stays and the access policy idea in `ideas.md` becomes a follow-up. Today the spec and the principle disagree silently. Checked: reading `vision.md` Principles and Story 1 AC 1.
- **G2 – the guest's actual goal.** Every story stops at the login page. That is the scope the operator chose after review 1 and the vision now supports it. But the product document `guest-access.md` is the only place a new operator session will look to onboard a guest; it should link to whatever account steps exist per service, even though they are not built here.
- **Overall**: Design may start. G1 and the Overseerr/Plex point in Story 1(b) and Story 2 should be answered by the operator first, because they decide whether Story 2 AC 4 is achievable without touching Plex.
