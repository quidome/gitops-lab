# TrueNAS exporter

What the TrueNAS exporter does **now**, for the operator. Updated with each change that changes it.

## Purpose
The TrueNAS NAS (172.16.40.64, TrueNAS 25.10) holds all storage of the platform in two pools:
`datapool` (the iSCSI and NFS volumes of the services) and `bigdata` (the media folders). The
exporter gives the size, the space in use and the health of each pool to Prometheus, so that the
operator gets one alert per pool when it fills up or is not healthy. It also passes on the alerts
that TrueNAS raises itself (disks, SMART tests, scrubs, replication, certificates), so that they
reach the operator through Alertmanager and Pushover.

Before, a full `bigdata` pool gave 8 critical alerts: the standard volume alert
(`KubePersistentVolumeFillingUp`) fired once for each fixed media volume, and 4 services mount
each of the two media folders.

## Behaviour
- Deployment `truenas-exporter` in namespace `observability`: one pod that runs a small Python
  script (`helm-chart/files/exporter.py`, Python standard library only) in the official Python
  Alpine image. The script is in a ConfigMap; there is no own image.
- Each minute Prometheus scrapes `/metrics`. For each scrape the script opens a secure websocket
  to the TrueNAS JSON-RPC API (`wss://172.16.40.64/api/current`), logs in with the API key
  (`auth.login_with_api_key`), calls `pool.query` and `alert.list`, and closes the connection.
- Why JSON-RPC and not the REST API (`/api/v2.0`): on TrueNAS 25.10 the REST API answered
  HTTP 403 to the read-only user and worked only for a full administrator. The JSON-RPC API
  honours the read-only roles. The REST API is also deprecated and will be removed.
- Metrics:
  - `truenas_pool_size_bytes`, `truenas_pool_allocated_bytes`, `truenas_pool_free_bytes` (label
    `pool`): raw pool size and space, as `zpool list` shows them. With RAIDZ these include parity,
    so they differ from the free space that a share shows.
  - `truenas_pool_healthy`: 1 when TrueNAS reports the pool as healthy, else 0.
  - `truenas_alert_active`: 1 for each TrueNAS alert that is not dismissed, with the labels `klass`
    (the kind of alert), `level` (INFO up to EMERGENCY), `text` (the message) and `uuid`. An alert
    that is dismissed in TrueNAS also stops in Alertmanager.
  - `truenas_up`: 1 when the last scrape of the TrueNAS API worked. A failure is written to the pod
    log.
- Alerts (PrometheusRule `truenas-exporter`):

  | Alert | When | Severity |
  |---|---|---|
  | `TrueNASPoolFillingUp` | pool more than 85 % in use for 15 min | warning (Pushover, no sound) |
  | `TrueNASPoolAlmostFull` | pool more than 95 % in use for 5 min | critical (Pushover) |
  | `TrueNASPoolUnhealthy` | TrueNAS reports the pool as not healthy for 5 min | critical (Pushover) |
  | `TrueNASAlert` | a TrueNAS alert with level WARNING | warning (Pushover, no sound) |
  | `TrueNASAlert` | a TrueNAS alert with level ERROR, CRITICAL, ALERT or EMERGENCY | critical (Pushover) |
  | `TrueNASExporterDown` | no pool data for 15 min | warning (Pushover, no sound) |

  `TrueNASAlert` leaves out the TrueNAS kinds for pool capacity and pool status
  (`ZpoolCapacity*`, `VolumeStatus`): the pool alerts above cover them. INFO and NOTICE alerts
  are only metrics.
- The fixed media volume claims have the label `excluded_from_alerts: "true"` (set in the
  charts in `gitops-apps`), so the standard volume alerts skip them. kube-state-metrics exports
  this label (`metricLabelsAllowlist` in `infrastructure/observability/kube-prometheus-stack/values.yaml`).
- Chart: `infrastructure/observability/truenas-exporter/`. Deployed by ArgoCD (application
  `truenas-exporter`).

## Secrets
- Vault `kv/observability/truenas-exporter`, key `API_KEY`: API key of the TrueNAS user
  `prometheus`. The user is in the group `prometheus`; the privilege `prometheus-pool-read` gives
  that group only the roles `POOL_READ` and `ALERT_LIST_READ`. The user is not a local
  administrator. To read more of the NAS later, add roles to that privilege; the key stays the
  same. Vals puts the key in the Secret `truenas-exporter` at sync time.
- TrueNAS revokes an API key that is ever sent over plain HTTP. The exporter uses only `wss://`;
  test the key only with `https://` or `wss://`.

## Test by hand
From a workstation, with the key in `$API_KEY`:

```
TRUENAS_HOST=172.16.40.64 TRUENAS_API_KEY="$API_KEY" \
  python3 infrastructure/observability/truenas-exporter/helm-chart/files/exporter.py --once
```

It prints the metrics of one scrape, or `truenas_up 0` and the error.

## Recovery steps
The exporter keeps no data. To bring it back:
1. `TrueNASExporterDown` fires: read the error in the pod log
   (`kubectl -n observability logs deploy/truenas-exporter`).
2. "TrueNAS refused the API key": the key is revoked or wrong. In the TrueNAS web UI, open the
   user icon (top right) → API Keys, and create a new key for the user `prometheus`. Store it with
   `kubectl exec -it -n security vault-0 -- vault kv put kv/observability/truenas-exporter API_KEY=<key>`,
   then `just sync truenas-exporter`.
3. An error that names `pool.query` or `alert.list` (not authorized): a role is missing in the
   privilege `prometheus-pool-read`.
4. "websocket handshake failed": the API path changed after a TrueNAS upgrade. Check the API
   documentation of the new version (`https://172.16.40.64/api/docs/`).
