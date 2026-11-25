# k3s certificates and admin access

How the k3s certificates of the platform work **now**, how the operator gets alerts before they
expire, and the recovery steps. Updated with each change that changes it.

## Purpose
k3s uses certificates for all traffic inside the cluster (API server, kubelets, controllers) and
for the operator's `kubectl` (the admin client certificate). When a certificate expires, that part
stops working. On 2026-11-23 the admin certificate in the workstation kubeconfig expired, and
`kubectl` failed with "the server has asked for the client to provide credentials". This document
makes sure that the next expiry is seen weeks before, and that it is quick to fix.

## Behaviour
- **Nodes:** `kube2` (172.16.40.76) is the only k3s server; `kube1` and `kube3` are agents. The
  NixOS configuration of the nodes is in the repository `nixos-config` (`hosts/kube*/configuration.nix`).
- **Lifetimes:**
  - Client and server certificates: 365 days.
  - The certificate authorities (CA) of the cluster: 3650 days (created 2025-07-20, so they
    expire around 2035-07). k3s never renews them by itself (`k3s certificate rotate-ca`).
  - The serving certificate of the API port 6443 (`CN=k3s`) is managed by a separate part of
    k3s (dynamiclistener) and has its own date.
- **Renewal:** k3s renews each client and server certificate that is expired or expires within
  120 days, **only when k3s starts**. A node that runs without a k3s restart for a long time
  keeps its old certificates until they expire. k3s also creates a Kubernetes event
  `CertificateExpirationWarning` on the node when a certificate is within 120 days.
- **Admin kubeconfig:** k3s writes `/etc/rancher/k3s/k3s.yaml` on `kube2` (root only) with the
  current admin certificate. The copy on the workstation (`~/.kube/config`) does not change when
  k3s renews: it must be fetched again (`just kubeconfig`).
- **Metrics:**
  - k3s on `kube2` runs with `--supervisor-metrics`. k3s then adds
    `k3s_certificate_expiration_seconds` (labels `subject`, `usages`: seconds until each
    certificate expires) to `/metrics`. Prometheus already scrapes it on `kube2` (jobs
    `apiserver` and `kubelet`) and on the agents (job `kubelet`), so the certificates of all three
    nodes are covered.
  - The API serving certificate (`CN=k3s`) is not in that metric. The blackbox exporter makes a
    TLS handshake with `172.16.40.76:6443` (probe `blackbox-k3s-api-tls`) and reads its expiry
    date (`probe_ssl_earliest_cert_expiry`).
  - The recording rule `k3s:certificate_expiration_seconds:min` joins both, with one series per
    node address (`node`), `subject` and `usages`. The alerts use it.
- **Alerts** (`additionalPrometheusRulesMap` in `infrastructure/observability/kube-prometheus-stack/values.yaml`):

  | Alert | When | Severity |
  |---|---|---|
  | `K3sCertificateExpiresSoon` | a k3s certificate expires within 45 days | warning (Pushover, no sound) |
  | `K3sCertificateExpiresVerySoon` | a k3s certificate expires within 14 days | critical (Pushover) |
  | `K3sCertificateMetricMissing` | no `k3s_certificate_expiration_seconds` or no TLS probe result for 1 h | warning (Pushover, no sound) |

  The standard alerts of kube-prometheus-stack also stay: `KubeClientCertificateExpiration`
  (a client certificate used against the API server expires within 7 days or 24 hours) and the
  kubelet certificate alerts.
- **Dates on 2026-11-25:**
  - Most client and server certificates on `kube2`, the admin certificate included, expire on
    2027-08-03. A k3s restart from 2027-04-05 (120 days before) renews them.
  - The API serving certificate (`CN=k3s`) expires on 2027-04-07. dynamiclistener probably
    renews it while k3s runs, but this has not been seen yet; the alerts show it if it does not.

## Secrets
- The private keys of all certificates are on the nodes in `/var/lib/rancher/k3s/server/tls/`
  (server) and `/var/lib/rancher/k3s/agent/` (agents). They are not in Vault or git.
- The admin kubeconfig gives full access to the cluster. Keep it only in `~/.kube/config`
  (mode 600) on the workstation. `just kubeconfig` keeps the old file as
  `~/.kube/config.bak-<date>`; delete old backups.

## Recovery steps

### `kubectl` fails with "the server has asked for the client to provide credentials"
The workstation copy of the admin certificate is expired or old.
1. `just kubeconfig` (asks for the sudo password on `kube2`). It copies `k3s.yaml` from `kube2`,
   sets the server address `https://172.16.40.76:6443`, checks that it works, and keeps a backup
   of the old file.
2. If the new file also fails, the admin certificate on `kube2` is expired too: do the next
   section, then step 1 again.

### `K3sCertificateExpiresSoon` or `K3sCertificateExpiresVerySoon` fires
1. On the node: `ssh <node>`, then `sudo k3s certificate check --output table` to see which
   certificates expire and when.
2. `sudo systemctl restart k3s` (the unit is called `k3s` on the server and on the agents). On `kube2`
   the Kubernetes API is gone for about a minute; the pods keep running.
3. `sudo k3s certificate check --output table` again: the dates must be one year from now.
4. On the workstation: `just kubeconfig`, because the admin certificate is new.
5. In Prometheus, `k3s_certificate_expiration_seconds` shows the new dates after the next scrape,
   and the alert resolves.

A restart renews only certificates that expire within 120 days. To renew earlier, stop k3s,
run `sudo k3s certificate rotate`, and start k3s.

### Certificates have already expired (the cluster does not work)
A k3s start also renews expired certificates. Do the steps of the section above on `kube2`
first, then on the agents. If the agents still cannot join, restart `k3s` on each agent
after `kube2` is up.

### `K3sCertificateMetricMissing` fires
The flag `--supervisor-metrics` is gone from k3s on `kube2`, for example after a change in
`nixos-config`. Check `services.k3s.extraFlags` in `hosts/kube2/configuration.nix`, and
`kubectl get --raw /metrics | grep k3s_certificate_expiration_seconds`. Until it is fixed, check
the dates by hand with `sudo k3s certificate check --output table`.
