# FreshRSS

Initial GitOps scaffold for internal-only FreshRSS deployment.

## Notes

- Uses a local minimal Helm chart (`helm-chart/`) for full control.
- Persists FreshRSS data at `/var/www/FreshRSS/data` on an RWO PVC.
- Deployment strategy is `Recreate` to avoid RWO multi-attach issues.
- Exposed internally via `gateway-internal` at `https://rss.quido.me`.

## Follow-up items

- Populate Vault path `kv/productivity/freshrss` with keys:
  - `FRESHRSS_USER`
  - `FRESHRSS_PASSWORD`
- Secrets are injected at deploy-time via Vals in `helmfile.yaml.gotmpl`.
- Validate iOS client compatibility and document tested client(s).
- Decide whether to keep SQLite-only or move to PostgreSQL/MariaDB.
