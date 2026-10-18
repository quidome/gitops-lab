# Implementation Tasks: Notifications and Outbound E-mail

Based on: `tasks/prd-notifications-and-email.md`

## Relevant Files

- `tasks/prd-notifications-and-email.md` - Approved requirements and success metrics.
- `tasks/tasks-notifications-and-email.md` - This implementation checklist.
- `infrastructure/observability/kube-prometheus-stack/values.yaml` - Alertmanager route tree (which alert goes to which receiver).
- `infrastructure/observability/kube-prometheus-stack/secrets.yaml.gotmpl` - Alertmanager receivers with Vault-backed Pushover keys and the healthchecks.io ping URL. Receivers must stay here because Helm replaces lists instead of merging them.
- `infrastructure/gitops/argocd/values.yaml` - ArgoCD controller metrics and ServiceMonitor settings.
- `infrastructure/gitops/argocd/resources/templates/prometheus-rule.yaml` - New PrometheusRule with `ArgoAppUnhealthy` and `ArgoAppOutOfSync`.
- `infrastructure/security/pocket-id/helmfile.yaml.gotmpl` - Vault-backed SMTP values for Pocket-ID.
- `infrastructure/security/pocket-id/helm-chart/values.yaml` - Non-secret Pocket-ID settings (new `app.config` block).
- `infrastructure/security/pocket-id/helm-chart/templates/deployment.yaml` - Environment variables for all Pocket-ID settings and SMTP.
- `infrastructure/security/pocket-id/helm-chart/templates/secret.yaml` - `pocket-id-secrets` Secret, extended with SMTP user and password.
- `infrastructure/security/pocket-id/README.md` - Pocket-ID settings and mail documentation.
- `infrastructure/observability/kube-prometheus-stack/README.md` - Alert routing, Pushover and heartbeat documentation.
- `AGENTS.md` - Vault path table (add `kv/shared/smtp` and the new `kv/observability/alertmanager` key).

### Notes

- There are no unit tests in this repository. Validate with local renders: `helm template` for local charts (use placeholder values for secrets), and `helmfile -f <file> template` when a Vault connection is available. Do not keep rendered output; it can contain secrets.
- Never commit secrets, keys, tokens, ping URLs or rendered Secret values. Secrets go in Vault only.
- Do not deploy with `helm install`, `helm upgrade` or `kubectl apply`. Merge to `main` and let ArgoCD sync.
- There is no argocd CLI. Use `kubectl get application <name> -n gitops`.
- After a Vault change, refresh the app: `kubectl patch application <app> -n gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'`.
- Tasks marked **(owner)** need the lab owner (accounts, phone, Cloudflare, Vault writes). A developer cannot do them alone.
- Tasks 1.0 to 5.0 can each be a separate pull request. Do 1.0 before 2.0, and 4.0 before 5.0.

## Instructions for Completing Tasks

**IMPORTANT:** As you complete each task, you must check it off in this markdown file by changing `- [ ]` to `- [x]`. This helps track progress and ensures you don't skip any steps.

Example:
- `- [ ] 1.1 Read file` → `- [x] 1.1 Read file` (after completing)

Update the file after completing each sub-task, not just after completing an entire parent task.

## Tasks

- [ ] 0.0 Create feature branch
  - [ ] 0.1 Create and check out a branch from `main`: `git checkout -b feat/notifications-and-email`. (Use one branch per pull request if you split tasks 1.0 to 5.0, for example `feat/alert-routing`, `feat/pocket-id-mail`.)

- [ ] 1.0 Make Pushover reach the iPhone for critical and warning alerts (PRD section A)
  - [ ] 1.1 **(owner)** Install the Pushover iOS app and sign in.
  - [ ] 1.2 **(owner)** Compare the user key shown in the app and the app token on pushover.net with Vault `kv/observability/alertmanager` (`pushover-user-key`, `pushover-api-token`). Replace them in Vault if they differ. Do not paste the values in chat or Git.
  - [ ] 1.3 **(owner)** Send one test message with the Vault values (for example with `curl` to the Pushover API, from your own shell) and confirm it shows on the phone.
  - [ ] 1.4 In `secrets.yaml.gotmpl`, replace receiver `pushover` with `pushover-critical` (`priority: "1"`, `send_resolved: true`) and `pushover-warning` (`priority: "0"`, `send_resolved: true`). Both use the same two `fetchSecretValue` lines. Keep receiver `"null"`.
  - [ ] 1.5 In `values.yaml`, under `alertmanager.config.route.routes`, replace the `pushover` route with: `severity=critical` → `pushover-critical` (`repeat_interval: 4h`), then `severity=warning` → `pushover-warning` (`repeat_interval: 24h`). Leave the root `receiver: "null"`. Leave room for the `Watchdog` route from task 2.0 as the first route.
  - [ ] 1.6 Render the chart locally (task 6.1 method) and check that the Alertmanager config Secret has three receivers and the expected routes.
  - [ ] 1.7 Open a pull request, merge it, and wait until `kube-prometheus-stack` is `Synced` and `Healthy` in ArgoCD.
  - [ ] 1.8 Check the loaded config in the pod: `kubectl -n observability exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- amtool config routes --config.file=/etc/alertmanager/config_out/alertmanager.env.yaml`.
  - [ ] 1.9 Send test alerts: inside the pod run `amtool alert add TestCritical severity=critical --alertmanager.url=http://localhost:9093` and the same with `TestWarning severity=warning`. Both must show on the phone within 5 minutes. Expect the existing `TargetDown` warnings to arrive too (about 6, accepted in the PRD).
  - [ ] 1.10 Check `alertmanager_notifications_total{integration="pushover"}` grows and `alertmanager_notifications_failed_total{integration="pushover"}` stays 0.

- [ ] 2.0 Add the healthchecks.io heartbeat for the Watchdog alert (PRD section B)
  - [ ] 2.1 **(owner)** Create a healthchecks.io account and a check named `gitops-lab-alertmanager` with period 5 minutes and grace time 10 minutes.
  - [ ] 2.2 **(owner)** In healthchecks.io, add the Pushover integration and an e-mail integration to your Gmail, and connect both to the check.
  - [ ] 2.3 **(owner)** Store the ping URL in Vault at `kv/observability/alertmanager#healthchecks-ping-url`. Keep the existing keys at that path.
  - [ ] 2.4 In `secrets.yaml.gotmpl`, add receiver `healthchecks` with `webhook_configs: [{url: <fetchSecretValue of the ping URL>, send_resolved: false}]`.
  - [ ] 2.5 In `values.yaml`, add as the **first** route: matcher `alertname=Watchdog`, receiver `healthchecks`, `group_wait: 0s`, `group_interval: 1m`, `repeat_interval: 5m`, `continue: false`.
  - [ ] 2.6 Render locally, open a pull request, merge, and wait for `Synced` and `Healthy`.
  - [ ] 2.7 Check healthchecks.io shows the check as "up" and pings arrive about every 5 minutes for 30 minutes.

- [ ] 3.0 Scrape ArgoCD metrics and alert on unhealthy or out-of-sync apps (PRD section C)
  - [ ] 3.1 In `infrastructure/gitops/argocd/values.yaml`, under `controller:`, add `metrics.enabled: true` and `metrics.serviceMonitor.enabled: true`. Check the exact keys in the `argo-cd` chart version `10.9.6` values.
  - [ ] 3.2 Check that the NetworkPolicy `argocd-application-controller` (namespace `gitops`, created by the ArgoCD chart) allows traffic from namespace `observability` to the metrics port (`8082` by default). Read it with `kubectl -n gitops get networkpolicy argocd-application-controller -o yaml`. If it blocks the port, add the needed rule through the chart values.
  - [ ] 3.3 Create `infrastructure/gitops/argocd/resources/templates/prometheus-rule.yaml` with a `PrometheusRule` in namespace `gitops` and two alerts:
    - `ArgoAppUnhealthy`: `argocd_app_info{health_status=~"Degraded|Missing"} == 1` (or `> 0`) for `15m`, `severity: warning`.
    - `ArgoAppOutOfSync`: `argocd_app_info{sync_status="OutOfSync"} == 1` (or `> 0`) for `1h`, `severity: warning`.
    Add a `summary` annotation that uses `{{ "{{" }} $labels.name {{ "}}" }}` so the push message names the app. Escape the Prometheus `{{ }}` so Helm does not render them.
  - [ ] 3.4 Render the `argocd-resources` chart locally (`helm template infrastructure/gitops/argocd/resources -f infrastructure/gitops/argocd/values.yaml`) and check the rule expressions are not changed by Helm.
  - [ ] 3.5 Open a pull request, merge, and wait for the `argocd` app to be `Synced` and `Healthy`.
  - [ ] 3.6 In Prometheus (Grafana Explore or the Prometheus UI), check the ArgoCD target is `up` and `argocd_app_info` returns one series per app.
  - [ ] 3.7 Check the two rules are loaded (Prometheus "Rules" page) and are not firing for healthy apps.
  - [ ] 3.8 Test: make one app unhealthy on purpose for more than 15 minutes (for example a temporary bad image tag on a non-critical app on a test branch target, or scale a test Deployment to a bad state). Confirm `ArgoAppUnhealthy` fires and a push arrives. Revert.

- [ ] 4.0 Set up Brevo, the `mail.quido.me` DNS records and the shared SMTP secret (PRD section D)
  - [ ] 4.1 **(owner)** Create a Brevo account (free plan). Expect a possible manual account review.
  - [ ] 4.2 **(owner)** In Brevo, add sender domain `mail.quido.me` and choose manual DNS setup.
  - [ ] 4.3 **(owner)** In Cloudflare, add the TXT records Brevo shows (Brevo code and DKIM). Add SPF TXT on `mail.quido.me`: `v=spf1 include:spf.brevo.com ~all`. Add DMARC TXT on `_dmarc.mail.quido.me`: `v=DMARC1; p=none; rua=mailto:<your gmail>`. Add nothing on `quido.me` itself.
  - [ ] 4.4 Check the records from outside: `dig +short TXT mail.quido.me @1.1.1.1` and `dig +short TXT _dmarc.mail.quido.me @1.1.1.1`. Also confirm `dig +short MX quido.me` and `dig +short TXT quido.me` are still empty.
  - [ ] 4.5 **(owner)** In Brevo, run "Authenticate" for the domain and confirm the status is authenticated.
  - [ ] 4.6 **(owner)** Create an SMTP key in Brevo (SMTP & API settings). Store in Vault at `kv/shared/smtp`: `host` = `smtp-relay.brevo.com`, `port` = `587`, `username` (Brevo SMTP login), `password` (the SMTP key), `from` = `noreply@mail.quido.me`, `reply-to` = your Gmail address.
  - [ ] 4.7 **(owner)** Check that the Vault policy used by Vals (ArgoCD Helmfile plugin) can read `kv/shared/smtp`. See `infrastructure/security/vault/VALS-SETUP.md`. Add the path to the policy if it is limited by path.
  - [ ] 4.8 In `AGENTS.md`, add `kv/shared/smtp` (keys `host`, `port`, `username`, `password`, `from`, `reply-to`, used by Pocket-ID) and the new `kv/observability/alertmanager` keys to the Vault path table.

- [ ] 5.0 Move all Pocket-ID settings to Git and Vault and turn on e-mail (PRD section E)
  - [ ] 5.1 **(owner)** Sign in to `https://id.quido.me` as admin and write down every setting under Application Configuration (general, e-mail, sign-up, LDAP, images). Save the list (without secrets) in `infrastructure/security/pocket-id/README.md` or in the pull request description.
  - [ ] 5.2 Read the Pocket-ID docs for version `v2.16.0` (environment variables page). Confirm the exact names for: `UI_CONFIG_DISABLED`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_TLS`, `EMAIL_ONE_TIME_ACCESS_AS_UNAUTHENTICATED_ENABLED`, `EMAIL_ONE_TIME_ACCESS_AS_ADMIN_ENABLED`, `EMAIL_LOGIN_NOTIFICATION_ENABLED`, `ALLOW_USER_SIGNUPS`, `APP_NAME`, and the variable for every setting from 5.1. Also check if `SMTP_PASSWORD_FILE` (or a general `*_FILE` form) is supported. Write the answer to PRD open question 2 in the pull request.
  - [ ] 5.3 In `helm-chart/values.yaml`, add an `app.config` map with all non-secret settings from 5.1 and the new mail settings: `UI_CONFIG_DISABLED: "true"`, `SMTP_HOST: smtp-relay.brevo.com`, `SMTP_PORT: "587"`, `SMTP_TLS: starttls`, `SMTP_FROM: noreply@mail.quido.me`, the three `EMAIL_*` flags set to `"true"`, and `ALLOW_USER_SIGNUPS: withToken` (or the stricter current value from 5.1).
  - [ ] 5.4 In `templates/deployment.yaml`, add a loop over `.Values.app.config` that writes each entry as an `env` item (values quoted). Keep the existing `APP_URL`, `TRUST_PROXY` and `ENCRYPTION_KEY_FILE`.
  - [ ] 5.5 In `templates/secret.yaml`, add keys `smtp-user` and `smtp-password` from new values `app.smtpUser` and `app.smtpPassword`. Add both values as empty strings in `values.yaml`.
  - [ ] 5.6 In `templates/deployment.yaml`, pass the SMTP login to the container: if 5.2 confirmed `*_FILE` support, set `SMTP_PASSWORD_FILE=/run/secrets/pocket-id/smtp-password` (the Secret is already mounted there); otherwise use `SMTP_PASSWORD` with `valueFrom.secretKeyRef`. Do the same for `SMTP_USER`.
  - [ ] 5.7 In `helmfile.yaml.gotmpl`, add `smtpUser` and `smtpPassword` to the environment values with `fetchSecretValue "ref+vault://kv/shared/smtp#username"` and `#password`, and pass them to the release as `app.smtpUser` and `app.smtpPassword`, like `encryptionKey`.
  - [ ] 5.8 Render the chart locally with placeholder secrets (`helm template infrastructure/security/pocket-id/helm-chart --set app.smtpPassword=x --set app.smtpUser=y --set app.encryptionKey=z`). Check every setting from 5.1 is present and no real secret is in any file.
  - [ ] 5.9 Open a pull request, merge, and wait for `pocket-id` to be `Synced` and `Healthy`. The Deployment uses `Recreate`, so expect a short login outage during the rollout.
  - [ ] 5.10 Check the logs (`kubectl -n security logs deploy/pocket-id`) for config or SMTP errors.
  - [ ] 5.11 **(owner)** In the admin screen, confirm the settings are read-only and match the list from 5.1. Send a test e-mail from the admin screen if Pocket-ID offers one.
  - [ ] 5.12 **(owner)** Sign out, request a login code by e-mail, and sign in with it. Then sign in from a new browser and confirm the new sign-in notice arrives.

- [ ] 6.0 Verify end to end and update documentation (PRD sections 8 and 9)
  - [ ] 6.1 For each changed Helmfile, run `helmfile -f <path> template` with a working Vault connection, or `helm template` on local charts with placeholder values if Vault is not reachable from the workstation. Do not keep the output.
  - [ ] 6.2 Check all apps are `Synced` and `Healthy`: `kubectl get applications -n gitops`.
  - [ ] 6.3 Heartbeat failure test: scale Alertmanager to 0 (`kubectl -n observability patch alertmanager kube-prometheus-stack-alertmanager --type merge -p '{"spec":{"replicas":0}}'`), wait about 20 minutes, confirm the healthchecks.io "down" push and mail arrive, then set replicas back to 1 and confirm the "up" message. Note: ArgoCD self-heal may restore the replica count early; if so, pause auto-sync for the app during the test and turn it back on after.
  - [ ] 6.4 **(owner)** In Gmail, open a Pocket-ID mail, choose "Show original", and confirm SPF, DKIM and DMARC are all `PASS`.
  - [ ] 6.5 Update `infrastructure/observability/kube-prometheus-stack/README.md`: receivers, routes, Pushover priorities, the heartbeat and how to test them.
  - [ ] 6.6 Update `infrastructure/security/pocket-id/README.md`: settings now come from Git (`UI_CONFIG_DISABLED=true`), where the SMTP secret lives, and how to change a setting.
  - [ ] 6.7 Resolve or carry forward the PRD open questions: Vault path choice (`kv/shared/smtp`), `*_FILE` support, the Pocket-ID settings list, and quiet hours for warnings. Write the answers in the PRD.
  - [ ] 6.8 After a few weeks of clean DMARC reports, **(owner)** change `_dmarc.mail.quido.me` to `p=quarantine`. Track this as a follow-up if it is not yet time.
