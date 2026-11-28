# 0004 – Push messages to the operator go through Pushover

**Status**: valid
**Date**: 2026-11-22

## Context
The operator must get a message on the iPhone when an alert fires, and also when the platform is
down and cannot send anything itself. Push messages to an iPhone always go through Apple's push
service, so each option needs a service outside the house.

The operator prefers open source and self-hosted software, also when an outside service is still
needed: the choice says something about the project. Paying a reasonable fee is fine. Telegram is
excluded.

The platform already had one attempt with self-hosted ntfy (a push server with an iOS app):

- **March 2026**: ntfy ran in `infrastructure/observability/ntfy/` with a bridge that formatted
  the Alertmanager messages. iOS push went through the relay at ntfy.sh (`upstream-base-url`,
  commit `ea6ab99`, 2026-03-06). Debugging of that relay started the same day (`d06734d`). On
  2026-03-21 ntfy and the bridge were removed and Alertmanager got a Pushover receiver
  (`e1d359f`, `34ae60b`). The exact cause of the relay problem was not written down. Getting push
  to the iPhone reliably was the problem, not the server itself.
- **November 2026**: the operator first chose self-hosted ntfy again, with the ntfy.sh relay on
  the free tier (250 messages a day). That plan needed the cause of the March problem to be found
  first, an exact match between the server address and the address in the iOS app, and Tailscale
  on the phone to fetch the message text when away from home. The same day the operator bought
  the Pushover app and dropped ntfy.

Options compared on 2026-11-22:

| Option | For | Against |
|---|---|---|
| Self-hosted ntfy, iOS push through ntfy.sh | Open source; alert text stays in the house | Failed in March for a reason not found; phone needs Tailscale away from home; more parts to run |
| Hosted ntfy.sh (free or Supporter, $5 a month) | Open source; no own server; reserved topics and phone calls on Supporter | Monthly fee for the useful parts; alert text stored at ntfy.sh |
| Signal | Open source, end-to-end encrypted | No built-in Alertmanager receiver; needs a bridge and a phone number |
| Matrix | Open source, can be self-hosted | No built-in Alertmanager receiver; a homeserver is a large service to run for alerts |
| Pushover | One-time cost; built-in Alertmanager receiver; priorities, including iOS critical alerts; healthchecks.io can send to it | Not open source; alert text stored at Pushover; no self-hosted exit path |

## Decision
- Alertmanager sends push messages to the operator through Pushover, with its built-in Pushover
  receiver. No bridge and no own push server.
- The alarm when the platform is down (healthchecks.io, outside the house) also sends through
  Pushover.
- The Pushover keys stay in Vault (`kv/observability/alertmanager`) and are injected with Vals.

## Consequences
- Accepted trade-offs: Pushover is not open source, it stores the alert text, and there is no
  self-hosted exit path. Alert text must not contain secrets.
- Moving to another push service later is a change of Alertmanager receivers only; alert rules
  and severities stay the same.
- Which severity gets which Pushover priority is in `docs/architecture.md` (Alerts and how they
  reach the operator).
- The self-hosted ntfy task is scrapped. The push parts of the old plan in
  `tasks/prd-notifications-and-email.md` now continue as Vikunja tasks #33 to #35.
