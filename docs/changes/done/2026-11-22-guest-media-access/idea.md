# Idea: Guest access to media apps over Tailscale

**Status**: ready for discovery            <!-- draft | ready for discovery -->
**Purpose fit**: Serves the first purpose (services that people use), now also for guests, and the second purpose (a lab to learn to run a platform well: a private-network entry, access limits per namespace, egress limits). It does not serve the current priorities (backups, alerting); the operator chose to do it now.
**Date**: 2026-11-22

## The problem
A few friends of the operator want to watch media from the platform (Jellyfin) and ask for new
media (Overseerr). Today only people on the home network can reach these apps. The operator
does not want to open anything to the public internet to give them access.

## The idea
- Guests reach **Jellyfin** (`flix.quido.me`) and **Overseerr** (`seerr.quido.me`) from their own devices, over Tailscale (a private network that runs over the internet). They use the same HTTPS names and the same certificate as the household.
- A guest makes a free Tailscale account and accepts a share (access to one single device on the operator's private network) from the operator. The guest sees only that one device, and on it only HTTP and HTTPS.
- Only services that the operator chose for sharing are reachable for guests. The choice is made in one place, in the platform, not in each app.
- **Plex** stays deployed but becomes reachable for the household only.
- Household members and the operator keep their current access, from home and also over Tailscale.
- Nothing is open to the public internet. The only public trace is one DNS record that points to a private Tailscale address.

## Why now
The operator chose to start this now, ahead of the backup and alerting work. The external
gateway is not used for internet access today (the router does not forward to it), so it can
change purpose without effect on anything open.

## How it fits
- The vision now says (2026-11-22) that guests may use some shared services, and only over a private network, never from the open internet. This idea is the first use of that rule.
- The apps (Jellyfin, Plex, Overseerr) and their routes are in the private second repository (`gitops-apps`). The platform part (gateway, Tailscale entry, network limits) is in this repository. The change touches both.
- Core value 2 (easy to manage, git is the truth): some parts are outside git: the Tailscale access policy, each guest's share, and one public DNS record. Discover must decide what can come into git and what stays a written manual step.
- Core value 1 (no data loss): the Tailscale entry keeps state (its identity and private address). If that state is lost, the address changes and the public DNS record and the guests' access break. That state needs a backup and recovery steps.
- Core value 3 (hardened): the Tailscale entry is a new way in. Its outgoing traffic must be limited, so that a problem in it stays contained.

## User view
- **A guest** gets an invite link from the operator, makes a Tailscale account, installs the Tailscale app, and accepts the share. After that the guest opens `flix.quido.me` or `seerr.quido.me` like any website. Awkward: the guest must keep the Tailscale app on, and must make an account with a third party.
- **A household member** sees no change for Jellyfin and Overseerr. Plex keeps working at home.
- **The operator** adds or removes a guest in the Tailscale admin console. The operator adds a service for guests by one change in the platform, not in the app.

## Open questions
For `/discover`:
1. Which steps stay manual (Tailscale access policy, the shares, the public DNS record), and where are they written down? Can the access policy come into git?
2. How does the operator back up the Tailscale entry's state so that its private address stays the same after a rebuild, and how is the restore shown to work?
3. How does a household member reach the apps when away from home (the operator says: through the subnet routes and split DNS of the existing Tailscale router `net1`; not checked)?
4. What does the operator see when a guest cannot connect (alerting for the new entry)?
5. How is a guest removed, and what does a removed guest still see?
6. Does Overseerr let a guest log in with a guest's own account, or does it need single sign-on?

## Notes for Design (from the operator, not checked)
The operator gave these technical choices. They are input for `/design`, not decisions yet.
- The external gateway (`gateway-external`, LAN address 172.16.40.51) is renamed to `gateway-shared`. Only namespaces with the label `expose=shared` (`media-server`, `media-tools`) can attach routes. The label list is in the gateway chart, not in the app charts.
- The Plex route moves to `gateway-internal`. The Jellyfin and Overseerr routes move to `gateway-shared` (in `gitops-apps`).
- The Tailscale Kubernetes operator: operator tag `tag:k8s-operator`, proxy tag `tag:k8s`, OAuth client in Vault at `kv/networking/tailscale-operator`. It exposes only the Service of the shared gateway, as tailnet device `shared-gw`, through the Gateway's `spec.infrastructure.annotations`.
- The gateway keeps its LAN address, because ExternalDNS publishes it to Technitium for the household.
- A CiliumNetworkPolicy limits the proxy's outgoing traffic to: kube-dns, kube-apiserver, the gateway, and public addresses only (TCP 443, UDP 3478, and UDP to all ports for peer connections).
- Tailscale access policy (already active): `autogroup:shared` gets `tcp:80` and `tcp:443` on `tag:k8s`.
- Public DNS gets one manual wildcard record `*.quido.me` to the proxy's 100.x address. The wildcard certificate (`cert-quidome`, `cloudflare-cluster-issuer`) and ExternalDNS stay as they are.
- Open: does Cilium 1.20.5 copy the infrastructure annotations to the gateway's Service? Fallback: a Service without a selector plus an EndpointSlice to 172.16.40.51.

Checked on 2026-11-22: `gateway-external` is at 172.16.40.51 and accepts routes from all namespaces; the Plex and Overseerr routes attach to it, the Jellyfin route to `gateway-internal`; Cilium is 1.20.5; ExternalDNS has a Technitium release; the namespaces `media-server` and `media-tools` exist; nothing in this repository or the cluster uses Tailscale yet.
