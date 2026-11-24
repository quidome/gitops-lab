# TrueNAS exporter

What the TrueNAS exporter does **now**, for the operator. Updated with each change that changes it.

## Purpose
The TrueNAS NAS (172.16.40.64) holds all storage of the platform in two pools: `datapool` (the
iSCSI and NFS volumes of the services) and `bigdata` (the media folders). The exporter gives the
size, the space in use and the health of each pool to Prometheus, so that the operator gets one
alert per pool when it fills up or is not healthy.

Before, a full `bigdata` pool gave 8 critical alerts: the standard volume alert
(`KubePersistentVolumeFillingUp`) fired once for each fixed media volume, and 4 services mount
each of the two media folders.

## Behaviour
- Deployment `truenas-exporter` in namespace `observability`, one pod with
  `json_exporter` (a Prometheus project exporter that turns a JSON API response into metrics).
- Each minute Prometheus asks the exporter for `/probe?module=pool&target=https://172.16.40.64/api/v2.0/pool`.
  The exporter calls the TrueNAS REST API with the API key and returns, per pool (label `pool`):
  - `truenas_pool_size_bytes`, `truenas_pool_allocated_bytes`, `truenas_pool_free_bytes`: raw pool
    size and space, as `zpool list` shows them. With RAIDZ these include parity, so they differ
    from the free space that a share shows.
  - `truenas_pool_healthy`: 1 when TrueNAS reports the pool as healthy, else 0.
- Alerts (PrometheusRule `truenas-exporter`):

  | Alert | When | Severity |
  |---|---|---|
  | `TrueNASPoolFillingUp` | pool more than 85 % in use for 15 min | warning |
  | `TrueNASPoolAlmostFull` | pool more than 95 % in use for 5 min | critical (Pushover) |
  | `TrueNASPoolUnhealthy` | TrueNAS reports the pool as not healthy for 5 min | critical (Pushover) |
  | `TrueNASExporterDown` | no pool data for 15 min | warning |

- The fixed media volume claims have the label `excluded_from_alerts: "true"` (set in the
  charts in `gitops-apps`), so the standard volume alerts skip them. kube-state-metrics exports
  this label (`metricLabelsAllowlist` in `infrastructure/observability/kube-prometheus-stack/values.yaml`).
- Chart: `infrastructure/observability/truenas-exporter/`. Deployed by ArgoCD (application
  `truenas-exporter`).

## Secrets
- Vault `kv/observability/truenas-exporter`, key `API_KEY`: API key of the TrueNAS user
  `prometheus`, which has the read-only administrator role (`READONLY_ADMIN`). Vals puts it in the
  Secret `truenas-exporter` at sync time.

## Limits
- The TrueNAS REST API (`/api/v2.0`) is deprecated since TrueNAS 25.04. It works in 25.10
  (Goldeye). Before an upgrade to a later version, check that it still exists; if not, the
  exporter needs the JSON-RPC API and `TrueNASExporterDown` fires.

## Recovery steps
The exporter keeps no data. To bring it back:
1. `TrueNASExporterDown` fires: check the pod logs
   (`kubectl -n observability logs deploy/truenas-exporter`) and the scrape result
   (`kubectl -n observability port-forward svc/truenas-exporter 7979` and open
   `http://localhost:7979/probe?module=pool&target=https://172.16.40.64/api/v2.0/pool`).
2. HTTP 401 from TrueNAS: the API key is revoked or wrong. In the TrueNAS web UI, open
   Credentials → Users → `prometheus` and create a new API key. Store it with
   `vault kv put kv/observability/truenas-exporter API_KEY=<key>`, then `just sync truenas-exporter`.
3. HTTP 404 or 405 from TrueNAS: the REST API is gone after an upgrade (see Limits).
