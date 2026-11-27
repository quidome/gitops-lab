# Home Assistant

What Home Assistant does **now**, for the operator. Updated with each change that changes it.

## Purpose
Home Assistant is the home automation app of the household. It controls and shows the devices in
the house: Zigbee devices (through zigbee2mqtt and mosquitto), the car (through
saic-mqtt-gateway and mosquitto), and the other integrations set up in its web UI. Users open it
at `https://hass.quido.me`.

## Behaviour
- StatefulSet `hass` in namespace `home-automation`, one pod. Chart `pajikos/home-assistant`;
  config in `applications/home-automation/hass/`. Deployed by ArgoCD (application `hass`).
- Release `hass-resources` (local chart in `resources/`) adds the HTTPRoute for `hass.quido.me`
  on the `https` listener of `gateway-internal`, and the Secret with the Prometheus token.
- `configuration.yaml` comes from `configuration.templateConfig` in `values.yaml`. With
  `forceInit: true` the init container writes it again at each start and keeps the old file as
  `configuration.yaml.<date>`. Change it in git, not in the pod. Automations, scripts, scenes,
  dashboards and integrations are set up in the web UI and stored on the volume.
- The `http:` block in `configuration.yaml` trusts the pod network (`10.42.0.0/16`) as proxy, so
  that requests through the gateway are accepted. Home Assistant 2027.2 removes this block; see
  https://tasks.quido.me/tasks/83.
- The pod runs privileged, to read the USB serial device `/dev/ttyUSB0` of the P1 meter (the
  smart electricity meter). It prefers a node with the label
  `feature.node.kubernetes.io/usb-p1-meter.present=true` (set by node-feature-discovery) but also
  starts without it. On 2026-11-27 no node had that label.
- Metrics: the Home Assistant Prometheus integration (`prometheus:` in `configuration.yaml`)
  serves all entities at `/api/prometheus`. The chart ServiceMonitor `hass` makes Prometheus
  scrape it each 60 s with a bearer token. Metrics start with `hass_` (for example
  `hass_sensor_power_w`, `hass_sensor_energy_kwh`, `hass_sensor_temperature_celsius`), job `hass`.
  State metrics have no area; join them with `hass_entity_info` (label `area`) and
  `hass_area_info` (label `area_name`) on `entity` and `area`.
- Grafana dashboards: the JSON files in `resources/dashboards/` become the ConfigMap
  `hass-grafana-dashboards`, which the Grafana sidecar loads into the folder "Home". Change them in
  git; a change in the Grafana UI is lost at the next load.
  - "Home Assistant - House overview": room temperature and humidity, outside temperature,
    lights, solar power and production, car battery, device batteries, and entities without a
    state. `hass_entity_available` is 0 for "unavailable" and for "unknown", so the panel leaves
    out the types where "unknown" is normal (buttons, notify, conversation, scenes, events,
    updates).

## Data
- Volume `hass-hass-0` (5 Gi, `truenas-iscsi`, Retain) mounted at `/config`: the database
  `home-assistant_v2.db` (history), `.storage/` (integrations, devices, users, dashboards),
  `automations.yaml`, `scripts.yaml`, `scenes.yaml`, `secrets.yaml`, `custom_components/`.
- Home Assistant makes a daily automatic backup (about 44 MB) in `/config/backups`. That folder is
  on the same volume, so it is not yet a backup that is safe outside the platform; see
  https://tasks.quido.me/tasks/84.

## Secrets
- Vault `kv/home-automation/hass`, key `PROMETHEUS_TOKEN`: a long-lived access token of a
  Home Assistant user, used by Prometheus to read `/api/prometheus`. Vals puts it in the Secret
  `hass-prometheus-token` at sync time. Long-lived tokens are valid for 10 years.
- Other credentials (integrations, MQTT user) are stored by Home Assistant on the volume.

## Recovery steps
1. **Pod does not start or is not ready**: read the log
   (`kubectl -n home-automation logs hass-0`). A configuration error in `configuration.yaml`
   comes from `templateConfig` in `values.yaml`; fix it in git and run `just sync hass`.
2. **`hass.quido.me` gives 400 Bad Request**: Home Assistant does not trust the proxy. Check the
   `http:` settings (trusted proxies) above.
3. **Prometheus target `serviceMonitor/home-automation/hass/0` is down with 401 or 403**: the token
   is revoked or wrong. In Home Assistant open the profile → Security → Long-lived access tokens
   and create a new token. Store it with
   `kubectl exec -it -n security vault-0 -- vault kv put kv/home-automation/hass PROMETHEUS_TOKEN=<token>`,
   then `just sync hass`.
4. **Sync of `hass` fails with a Vals error**: the Vault path `kv/home-automation/hass` or the key
   `PROMETHEUS_TOKEN` is missing, or Vault is sealed (`just unseal`). Nothing of `hass` deploys
   until it renders.
5. **Volume lost**: the PV is kept (Retain) on TrueNAS, so first try to bind the old volume again.
   If the data is gone: start Home Assistant with an empty volume, choose "Restore from backup" in
   the onboarding screen and upload an automatic backup (`Automatic_backup_*.tar`). This works
   only if a copy of the backup exists outside the volume.
