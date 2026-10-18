# Product vision: gitops-lab

## The user's problem space
There are two kinds of users.

- **The operator** (the owner of this repository) builds and runs the platform alone. The operator is an engineer who knows Linux and Kubernetes. The operator wants the platform to run with little attention, wants to know when something is wrong, and must never lose data.
- **The users** are the people in the household who use some of the services (for example Home Assistant, file sync, the RSS reader, the task list). They do not operate the platform. They want the services to work and to be easy to reach.

The platform has two purposes, and both are real: it runs services that the home uses, and it is a lab where the operator learns to run a platform well.

## What this product is
A home lab Kubernetes platform (k3s on NixOS), managed with GitOps: git holds the desired state, and ArgoCD applies it to the cluster. The platform gives the shared base (networking, DNS, certificates, secrets, storage, single sign-on, monitoring) and runs the services in this repository.

The platform also runs the apps of a second, private repository (`gitops-apps`), for apps that are not shown on GitHub. Those apps are not described in this vision.

It is **not** a system the house depends on to function: almost all of the house works when the cluster is down. Short outages are acceptable. Lost data is not.

## Core values
1. **No data loss.** This is the one thing that is not acceptable. Every service that keeps data has a backup, and the operator knows that the backup works.
2. **Easy to manage.** Git is the truth. Changes go through git and ArgoCD, and Renovate keeps versions current. Routine work needs no manual steps on the cluster.
3. **Hardened against problems.** A failure stays contained, and the operator hears about it before the users notice it.
4. **Easy to build again.** A rebuild from nothing starts with a few command-line steps written in the README. After that bootstrap, git and ArgoCD do the rest.
5. **A good experience for the users.** The services that people use work well and are easy to reach: one login, a clear HTTPS name for each service. When a service is not good for its users, the operator can see that.

## Where we are
- The platform runs: networking (Cilium, Gateway API, external DNS, Pi-hole, Unbound), certificates, secrets (Vault with deploy-time injection), storage on TrueNAS, and single sign-on (Pocket ID, oauth2-proxy).
- All infrastructure and apps are deployed with Helmfile through ArgoCD. Renovate opens update pull requests.
- Services for the household run: home automation, file sync, RSS reader, task list, UniFi controller.
- Monitoring exists in part: Prometheus, an alerts dashboard (Karma), push messages (ntfy), and monitoring for Proxmox, Vault and the router.
- The team database has a nightly encrypted dump with an alert, and its recovery steps were tested with a real restore (2026-10-18). The dumps are on TrueNAS only, so they are not yet a backup in our own meaning: a copy outside the platform is still missing.
- Rough: backups of service data are not yet a solved and checked part of the platform: the other services have no checked backups, and no copy is stored outside the platform. Alerting does not yet cover all services and users. Some follow-up work is open in the backlog (notifications and e-mail, Zigbee alerting, Vault login hardening).

## North star
The operator trusts the platform without checking it. Data is always safe and recoverable. When something goes wrong, the operator knows first, knows what is wrong, and has written steps to fix it. The users only notice that their services work.

## Where we are going
Operational excellence. In order:
1. **Backups** – because no data loss is the first core value.
2. **Alerting** – so that the operator knows when something fails, also when a backup fails, and when a service is not good for its users.
3. **Other operational work** – hardening, updates, and recovery steps for each service.

## Longer horizon
- Each service has a product document in `docs/product/`: what it does, how to use it, how to recover it.
- A rebuild from nothing is tested, not only written down.

## User journeys
- **The operator changes the platform.** The operator writes the change in git, renders it, opens a pull request and merges it. ArgoCD applies it. The operator never changes the cluster by hand for routine work.
- **The operator keeps things current.** Renovate opens an update pull request. The checks show if it is safe. The operator merges it, and the platform stays current without extra work.
- **Something breaks.** A service fails, a disk fills up, or a backup does not run. The operator gets a push message before a user complains, sees what is wrong, and follows the written recovery steps.
- **The platform is lost.** The operator runs the few bootstrap steps from the README. ArgoCD deploys everything from git, secrets come from Vault, and data comes back from backups.
- **A user opens a service.** The user goes to a clear HTTPS name, logs in once, and the service works. If it is slow or down, the operator can see it.

## Priorities
1. **Backups**, because data loss is the only thing that is not acceptable.
2. **Alerting**, because problems must reach the operator before they reach the users.
3. **Other operational work** (hardening, updates, recovery steps), because it makes the platform easy to manage and easy to build again.

## Principles
- Git is the truth. If it is not in git, it does not exist.
- Data safety comes before uptime.
- Manual work is acceptable only for the first bootstrap, and it must be written down.
- A service is not done until it has a backup (if it keeps data), alerting, and recovery steps.
- Keep it simple enough for one operator to run.

## Open questions
- What is out of scope for the platform (for example public access from the internet, or services for people outside the household)? No rule yet.

## Change log
| Date | Change |
|------|--------|
| 2026-10-10 | Vision created |
| 2026-10-18 | Where we are: the team database has a nightly encrypted dump with a tested restore, not yet a copy outside the platform (change `done/2026-10-18-team-database-backup`) |
