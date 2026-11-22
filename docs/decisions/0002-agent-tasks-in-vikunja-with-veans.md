# 0002 – Agent tasks in Vikunja with veans

**Status**: valid
**Date**: 2026-11-22

## Context
Tasks and the backlog for the platform are in Vikunja, which runs on the platform. Until now the
operator copied the task text into each agent session and moved tasks on the board by hand. The
operator wants coding agents to read and update the tasks themselves, for this repository and for
`gitops-apps`, in one Vikunja project (Platform).

Vikunja 2.8.0 gives two ways for an agent:

- **veans**: a CLI from the Vikunja repository. It makes a bot user per repository, gives it
  access to one project, and prints fixed working rules at each session start.
- **The built-in MCP server** (`/api/v2/mcp`, since 2.7.0): no install, reaches almost all of the
  API, but acts as the owner of the API token and has no working rules or branch link.

## Decision
Use veans.

- Changes show as `bot-gitops-lab`, not as the operator. The bot token can be revoked or renewed
  (`veans login`) without an effect on the operator's account.
- The working rules (claim → In Progress → In Review, only the operator closes) come with the tool
  and are printed again before each context summary.
- The Kanban board gets the columns Todo (existing "To-Do"), In Progress (existing "Doing"),
  In Review, Done and Scrapped.
- veans is installed from nixpkgs (`vikunja.veans`) in `nix-config`, role `dev`.
- `.veans.yml` (project, view and column IDs, no secrets) is in git. The bot token is in the
  operator's system keychain, not in git or Vault.

## Consequences
- **Setup needs a login session, not an API token.** Vikunja never lets API tokens use routes
  under `/user/` or `/tokens`, so `veans init --token <api-token>` fails at the bot step. Run
  `veans init` without `--token`; it logs in through the browser (Vikunja OAuth, then Pocket ID).
- Each repository that uses the Platform project needs its own `veans init` and gets its own bot.
- Each workstation needs `veans login` (or `veans init`) to put the bot token in its keychain.
- When the platform is down, agents cannot reach tasks; the operator gives the task text instead.
- The MCP server stays an option for work across all projects; it is not set up.
