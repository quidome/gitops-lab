---
title: Guest access to media apps over Tailscale
type: feature
stage: design
closure: checks      # set by /design; only the user lowers it
created: 2026-11-22
---

# Guest access to media apps over Tailscale

A few guests (friends outside the household) get access to Jellyfin and Overseerr over
Tailscale, with nothing open to the public internet. The current external gateway becomes a
gateway that only shared services can use.

## Log
| Date | Stage | Note |
|------|-------|------|
| 2026-11-22 | idea | created; vision and word list changed: new word "guest", open question on outside people answered |
| 2026-11-22 | idea | operator chose to start this now, ahead of the backup and alerting work in the backlog |
| 2026-11-22 | discover | idea approved (operator started `/discover`) |
| 2026-11-22 | discover | spec review 1: not passed. Story 2 (accounts) conflicted with the vision: guests need Plex access to log in to Overseerr. Operator chose to separate network access from accounts and logins; spec rewritten for network access only; vision principle and word list changed (shared service, shared entry) |
| 2026-11-22 | discover | spec review 2: passed (all stories serve, some with notes). Operator: Plex port forward was still open and is now removed; vision exception for manual guest management; guest load out of scope |
| 2026-11-22 | design | functional spec approved by the operator |
