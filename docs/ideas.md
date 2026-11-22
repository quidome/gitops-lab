# Ideas

Raw ideas, one line each. No judgement yet. `/vision idea: …` picks them up.
Add the date. Remove a line when it becomes a change, or mark it `(rejected: reason)`.
- 2026-10-18: An automatic, repeated restore test of the database dumps (for example monthly into a scratch namespace, with an alert when it fails), so the operator knows the dumps still restore. Left out of the team database backup.
- 2026-10-18: The word list may need a word for a copy of service data that is not yet a backup (stored on the platform, or never restored); the docs now say "dump". A question for `/vision`.
- 2026-11-22: Keep the Tailscale access policy (who can reach which tailnet device) in git and apply it from there, instead of only in the Tailscale admin console. Left out of the guest media access change.
- 2026-11-22: Overseerr logs in with Jellyfin accounts instead of Plex accounts, and every user and guest gets a Jellyfin account. Then guests need no access to the Plex server. Left out of the guest media access change (accounts are separate from network access).
- 2026-11-22: Plex as a shared service for guests, only if a guest's Plex app still gets a direct connection (not the Plex relay) through the shared entry. Left out of the guest media access change.
