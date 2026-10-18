# PRD: Notifications and Outbound E-mail

## 1. Introduction / Overview

The home lab has no working way to reach its owner.

- **Push messages:** Alertmanager (the Prometheus component that routes alerts) has a Pushover
  receiver, but only alerts with `severity=critical` go to it. All other alerts go to a receiver
  named `"null"` that drops them. On 2026-10-07 Alertmanager had sent 0 messages and had 0 failures.
  Six `warning` alerts were active and nobody was told. The owner also has no Pushover app on their
  iPhone, so even critical alerts would not arrive.
- **Dead cluster:** If the cluster or Alertmanager stops, no message is sent, because the sender
  is down too.
- **E-mail:** No app can send e-mail. Pocket-ID (the login provider at `id.quido.me`) cannot send
  login codes, sign-up mails or new sign-in notices.

**Goal:** The owner gets a push message on their iPhone when something in the lab breaks, gets a
message when the whole cluster is down, and Pocket-ID can send e-mail from `noreply@mail.quido.me`.

## 2. Goals

1. Every `critical` and `warning` alert reaches the owner's iPhone through Pushover within 5 minutes.
2. If Alertmanager stops sending its always-on `Watchdog` alert for more than 15 minutes, the owner
   gets a push message from healthchecks.io (an outside service).
3. ArgoCD apps that are unhealthy or stay out of sync create a `warning` alert, which follows goal 1.
4. Pocket-ID sends e-mail through Brevo (an EU mail relay) and the mail passes SPF, DKIM and DMARC
   checks (DNS-based checks that prove the mail is really from the domain).
5. All configuration is in Git, and all secrets are in Vault and injected with Vals. No setting is
   kept only in an app's admin screen.

## 3. User Stories

- As the lab owner, I want a push message on my iPhone when a service or target is down, so that I
  can fix it before I notice it some other way.
- As the lab owner, I want critical alerts to make a sound even in quiet hours, and warnings to be
  normal messages, so that I can tell urgent from not urgent.
- As the lab owner, I want to be told when the whole cluster is down, so that silence means "all is
  well" and not "nothing can report".
- As the lab owner, I want to know when an ArgoCD app fails, so that a broken deploy does not go
  unseen.
- As a Pocket-ID user, I want to get a login code by e-mail when I cannot use my passkey, so that I
  can still sign in.
- As the lab owner, I want an e-mail when someone signs in to my account from a new device, so that
  I see misuse early.
- As the lab owner, I want all of this in Git and Vault, so that a rebuild of the cluster restores it.

## 4. Functional Requirements

### A. Push messages (Pushover)

Files: `infrastructure/observability/kube-prometheus-stack/values.yaml` (routes) and
`infrastructure/observability/kube-prometheus-stack/secrets.yaml.gotmpl` (receivers; receivers must
stay in this file, because Helm replaces lists instead of merging them).

1. The owner must install the Pushover iOS app, sign in, and confirm that the user key and the app
   token in Vault `kv/observability/alertmanager` (`pushover-user-key`, `pushover-api-token`) belong
   to that account. Replace the values in Vault if they do not.
2. The system must have a receiver `pushover-critical` with `priority: "1"` (high priority) and
   `send_resolved: true`.
3. The system must have a receiver `pushover-warning` with `priority: "0"` (normal priority) and
   `send_resolved: true`.
4. Both receivers must read the user key and token from the same Vault keys with `fetchSecretValue`.
5. The route tree must send:
   - `alertname=Watchdog` → receiver `healthchecks` (see section B). This route must come first.
   - `severity=critical` → `pushover-critical`, `repeat_interval: 4h`.
   - `severity=warning` → `pushover-warning`, `repeat_interval: 24h`.
   - everything else (for example `severity=info`) → `"null"` (the root receiver, unchanged).
6. The existing `TargetDown` warnings are accepted: the first deploy will send about 6 pushes. No
   silence is needed.

### B. Heartbeat (healthchecks.io)

7. The owner must create a check on healthchecks.io with period 5 minutes and grace time 10 minutes,
   and connect the healthchecks.io Pushover integration and an e-mail to their Gmail.
8. The ping URL must be stored in Vault at `kv/observability/alertmanager#healthchecks-ping-url`.
9. The system must have a receiver `healthchecks` with one `webhook_configs` entry whose `url` is
   the ping URL from Vault, and `send_resolved: false`.
10. The `Watchdog` route must use `group_wait: 0s`, `group_interval: 1m` and `repeat_interval: 5m`,
    so that the ping is sent at least every 5 minutes.

### C. ArgoCD alerts

Files: `infrastructure/gitops/argocd/values.yaml`, and a new PrometheusRule (for example in
`infrastructure/gitops/argocd/resources/` or the kube-prometheus-stack resources; follow the
existing pattern for extra manifests).

11. The ArgoCD application controller must expose metrics, and a ServiceMonitor must exist so that
    Prometheus scrapes them (`controller.metrics.enabled` and `controller.metrics.serviceMonitor.enabled`
    in the ArgoCD chart).
12. The existing NetworkPolicy `argocd-application-controller` in namespace `gitops` must allow
    Prometheus (namespace `observability`) to reach the metrics port. Check this; change it only if
    scraping fails.
13. A PrometheusRule must create alert `ArgoAppUnhealthy` (`severity: warning`) when an app has
    health status `Degraded` or `Missing` for 15 minutes.
14. A PrometheusRule must create alert `ArgoAppOutOfSync` (`severity: warning`) when an app is
    `OutOfSync` for 1 hour.
15. Both alerts must have labels and annotations that name the app (`name` label from
    `argocd_app_info`) so the push message says which app failed.
16. ArgoCD's own notifications controller stays disabled (`notifications.enabled: false`). All
    alerts go through Alertmanager, so silences in Karma (the alert dashboard) work for all of them.

### D. Outbound mail (Brevo, domain `mail.quido.me`)

17. The owner must create a Brevo account and add sender domain `mail.quido.me`.
18. The owner must add these DNS records by hand in Cloudflare:
    - The TXT records that Brevo shows (Brevo verification code and DKIM key).
    - SPF on `mail.quido.me`: `v=spf1 include:spf.brevo.com ~all`.
    - DMARC on `_dmarc.mail.quido.me`: `v=DMARC1; p=none; rua=mailto:<owner gmail>`.
    - No records are added to `quido.me` itself. It must stay free for a personal mail provider.
19. The owner must create an SMTP key in Brevo and store it in Vault at `kv/shared/smtp` with keys
    `host` (`smtp-relay.brevo.com`), `port` (`587`), `username`, `password`,
    `from` (`noreply@mail.quido.me`) and `reply-to` (owner's Gmail address).
20. `AGENTS.md` must list `kv/shared/smtp` in the Vault path table.

### E. Pocket-ID mail, fully in Git

Files: `infrastructure/security/pocket-id/helmfile.yaml.gotmpl`,
`infrastructure/security/pocket-id/helm-chart/values.yaml`,
`infrastructure/security/pocket-id/helm-chart/templates/deployment.yaml` and the template that
creates the `pocket-id-secrets` Secret.

21. Before any change, the developer must write down all current settings from the Pocket-ID admin
    screen (Application Configuration: general, e-mail, sign-up, LDAP, images), so no setting is lost.
22. Pocket-ID must run with `UI_CONFIG_DISABLED=true`, so all settings come from environment
    variables and the admin screen cannot change them.
23. Every setting from requirement 21 that is not a default must be set as an environment variable,
    with its value in `helm-chart/values.yaml` (for example under `app.config`).
24. The SMTP settings must be set with Pocket-ID's environment variables (`SMTP_HOST`, `SMTP_PORT`,
    `SMTP_FROM`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_TLS=starttls`). Check the exact names in the
    Pocket-ID v2.16 docs.
25. `SMTP_PASSWORD` and `SMTP_USER` must come from Vault `kv/shared/smtp` through
    `fetchSecretValue` in `helmfile.yaml.gotmpl`, be stored in the `pocket-id-secrets` Secret, and be
    passed to the container from that Secret (or as a `*_FILE` variable, like `ENCRYPTION_KEY_FILE`,
    if Pocket-ID supports it for these values). The password must never be in `values.yaml` or Git.
26. These e-mail features must be on: login code by e-mail for users who are not signed in
    (`EMAIL_ONE_TIME_ACCESS_AS_UNAUTHENTICATED_ENABLED`), login code sent by the admin
    (`EMAIL_ONE_TIME_ACCESS_AS_ADMIN_ENABLED`), and new sign-in notice
    (`EMAIL_LOGIN_NOTIFICATION_ENABLED`).
27. User sign-up must stay limited to sign-up tokens (`ALLOW_USER_SIGNUPS=withToken`), unless the
    current setting from requirement 21 is stricter; then keep the current setting.
28. A rollout must be possible without data loss: the change only adds environment variables, and
    the PVC and `Recreate` strategy stay the same.

## 5. Non-Goals (Out of Scope)

- Receiving e-mail, mailboxes, or any MX record on `quido.me` or `mail.quido.me`.
- Mail for Vikunja, Grafana, or a mail copy of alerts from Alertmanager (later PRD).
- Self-hosted push services (ntfy, Gotify). iOS push needs Apple's service, so self-hosting gives no
  real benefit.
- Fixing the current `TargetDown` alerts for `rt01` and `proxmox-exporter` (separate task).
- Managing Cloudflare DNS records from Git (they are added by hand).
- ArgoCD's own notifications controller.
- Alert tuning (changing which default rules exist, or their severity).

## 6. Design Considerations

- Push message titles must show the alert name and, where present, the namespace or app name.
  The default Pushover template from Alertmanager is fine for the first version.
- Mail from Pocket-ID uses its built-in templates. `APP_NAME` decides the sender name shown.

## 7. Technical Considerations

- Follow the secret pattern in `AGENTS.md`: Vals `fetchSecretValue` at deploy time, Vault paths in
  lowercase-kebab-case. `kv/shared/smtp` is a new shared path; it is shared because more apps will
  use it later.
- After a Vault change, refresh with:
  `kubectl patch application <app> -n gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'`.
- There is no argocd CLI; use `kubectl` for ArgoCD.
- Resource rules from `AGENTS.md` apply to anything new (CPU request only, memory request = limit).
- Pocket-ID image is `ghcr.io/pocket-id/pocket-id:v2.16.0`. Environment variable names must be
  checked against the docs for that version.
- Brevo SMTP uses port 587 with STARTTLS. Outbound traffic to the internet is not blocked by a
  NetworkPolicy in namespace `security` today; confirm during testing.
- Suggested order: A → B → C (alerting), then D → E (mail). Each part can be its own pull request.

## 8. Success Metrics

- A test alert with `severity=critical` and one with `severity=warning`
  (`amtool alert add ...` inside the Alertmanager pod) both show on the iPhone within 5 minutes.
- `alertmanager_notifications_total{integration="pushover"}` grows and
  `alertmanager_notifications_failed_total{integration="pushover"}` stays 0.
- healthchecks.io shows the check as "up", with pings every 5 minutes. When Alertmanager is scaled to
  0 for 20 minutes, a "down" push arrives; after restore, an "up" push arrives.
- An ArgoCD app forced into a bad state (test app or a temporary bad value) creates
  `ArgoAppUnhealthy` and a push.
- Brevo shows `mail.quido.me` as authenticated. A Pocket-ID login-code mail arrives in Gmail, and
  "Show original" shows SPF, DKIM and DMARC as PASS.
- The Pocket-ID admin screen shows settings as read-only, and all settings match the list from
  requirement 21.
- All ArgoCD apps are `Synced` and `Healthy` after each change (`kubectl get applications -n gitops`).

## 9. Open Questions

1. Is `kv/shared/smtp` the right Vault path, or should each app get its own copy under
   `kv/<realm>/<app>`?
2. Does Pocket-ID v2.16 support `*_FILE` variables for `SMTP_PASSWORD`?
3. Which admin-screen settings does Pocket-ID have today? (Answered during requirement 21.)
4. Should warnings have quiet hours (no push at night), or is normal priority enough?
