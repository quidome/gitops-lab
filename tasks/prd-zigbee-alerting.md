# PRD: Zigbee Alerting through Home Assistant Metrics

## 1. Introduction / Overview

Nobody is told when a Zigbee device stops working.

- **What happened:** On 2026-10-07 the storage room motion sensor (`motion sensor berging`) left the
  Zigbee network and did not come back. It sent nothing for about 61 hours. Nothing reported this.
  The owner found it only by checking by hand on 2026-10-09.
- **Why nothing saw it:** Zigbee2MQTT (the program that connects the Zigbee devices to MQTT) does
  not mark devices as offline, because its availability feature is off. Home Assistant (HA) keeps
  showing the last value of a dead device, so the sensor looked normal there too.
- **No metrics:** Prometheus (the metrics system in `infrastructure/observability/kube-prometheus-stack`)
  has no data about Zigbee devices, so no alert rule can check them.

**Goal:** When a Zigbee device goes offline, a battery gets low, the Zigbee2MQTT bridge goes down,
or HA stops giving metrics, Prometheus creates an alert. The alert goes through Alertmanager (the
Prometheus component that routes alerts), like all other alerts in the lab.

**Approach:**

1. Turn on the availability feature in Zigbee2MQTT, so dead devices become `unavailable` in HA.
2. Turn on the built-in Prometheus integration of HA. It shows the state of HA entities at the URL
   `/api/prometheus`.
3. Let Prometheus collect these metrics (with a ServiceMonitor) and add alert rules (a PrometheusRule).

## 2. Goals

1. A battery-powered Zigbee motion or climate sensor that sends nothing for 4 hours creates an
   alert within 20 minutes after that.
2. A mains-powered Zigbee device (lamp, plug, dimmer) that stops answering creates an alert within
   30 minutes.
3. A Zigbee battery below 20% creates an alert.
4. If the Zigbee2MQTT bridge is offline for 5 minutes, an alert is created.
5. If Prometheus cannot collect metrics from HA for 10 minutes, an alert is created.
6. All alerts have `severity: warning`.
7. All configuration is in Git, and the HA access token is in Vault and injected with Vals. No
   setting is kept only in an app's admin screen, with the exceptions given in section 7.

## 3. User Stories

- As the lab owner, I want to be told when a Zigbee sensor drops off the network, so that my
  automations (for example the hall light on motion) do not stop working without me knowing.
- As the lab owner, I want to be told when a battery is low, so that I can change it before the
  device dies.
- As the lab owner, I want to be told when Zigbee2MQTT itself is down, so that I know all Zigbee
  devices are affected at once.
- As the lab owner, I want to be told when HA stops giving metrics, so that silence from the Zigbee
  alerts does not mean "all is well" when in fact nothing is checked.
- As the lab owner, I want devices that are offline on purpose to not send alerts, so that the
  alerts I get are real.

## 4. Functional Requirements

### A. Zigbee2MQTT availability

File: `applications/home-automation/zigbee2mqtt/values.yaml`.

1. The system must turn on availability in Zigbee2MQTT:
   ```yaml
   availability:
     enabled: true
     active:
       timeout: 10    # minutes; mains-powered devices are checked actively
     passive:
       timeout: 240   # minutes; battery devices are offline after 4 hours of silence
   ```
   Check the exact keys against the documentation of the Zigbee2MQTT version that runs.
2. The system must turn off the availability check for these devices, so they never become
   `unavailable` and never create an "offline" alert:
   - `plug_4` (`0x38398ffffe0fbd90`) and `plug_5` (`0x3410f4fffe8f62ec`): offline since April 2026,
     kept on purpose.
   - `buttons - tv` (`0x540f57fffef95cda`) and `Button Attic` (`0x003c84fffed78c14`): IKEA remotes
     that send messages only when a button is pressed.

   In Zigbee2MQTT this is a per-device setting (`availability: false`). See section 7 for where to
   put it.
3. After the change, each Zigbee2MQTT device in HA must show `unavailable` when Zigbee2MQTT marks
   it offline. Test this with one device (see section 8).

### B. Home Assistant Prometheus integration

Files: `applications/home-automation/hass/values.yaml` and `applications/home-automation/hass/resources/`.

4. The system must turn on the HA Prometheus integration by adding a `prometheus:` block to
   `configuration.templateConfig` in `values.yaml`. The HA configuration file is created from this
   template (`forceInit: true`), so a change made only on the HA volume is lost.
5. The integration must keep authentication on (do NOT set `requires_auth: false`). HA can be
   reached from outside the cluster through the gateway, so open metrics would be public.
6. The integration must use a `filter` that includes only what the alerts need:
   - all entities of the Zigbee2MQTT devices (for `homeassistant_entity_available`);
   - all battery sensors (`sensor.*_battery`);
   - the Zigbee2MQTT bridge connection entity (`binary_sensor.zigbee2mqtt_bridge_connection_state`).

   Choose the filter keys (for example `include_entity_globs`) so that a new Zigbee device is
   included without a change to the filter, where possible.
7. The owner must create a long-lived access token in HA (Profile → Security → Long-lived access
   tokens), for a user made for this purpose (for example `prometheus`, not an admin if possible).
   Store it in Vault at `kv/home-automation/hass`, key `prometheus-token`. Add this path to the
   Vault table in `AGENTS.md`.
8. The system must create a Kubernetes Secret in namespace `home-automation` that holds the token.
   The token is injected with Vals at deploy time. Use `helmfile.yaml.gotmpl` and
   `fetchSecretValue` as in other components (see `AGENTS.md`, "Secret Injection with Vals").
9. The system must create a ServiceMonitor for HA that:
   - collects from path `/api/prometheus` on the HA Service port;
   - uses the token from the Secret in requirement 8 (`authorization` or `bearerTokenSecret`);
   - collects every 60 seconds;
   - has a job name that the alert rules can use (for example `hass`).

   Prometheus already finds all ServiceMonitors and PrometheusRules
   (`serviceMonitorSelector: {}` and `ruleSelector: {}` in kube-prometheus-stack), so no change is
   needed there.

### C. Alert rules

File: a PrometheusRule in `applications/home-automation/hass/resources/`. Use
`infrastructure/observability/vault-monitoring/helm-chart/templates/prometheusrule.yaml` as an
example for the layout and the labels (`prometheus: kube-prometheus-stack`,
`release: kube-prometheus-stack`).

10. The system must have these alert rules. All have `severity: warning`. Each alert must have a
    `summary` and a `description` that names the device (use the `friendly_name` or `entity` label).

    | Alert name | Fires when | `for` |
    |---|---|---|
    | `ZigbeeDeviceUnavailable` | An entity of a Zigbee2MQTT device has `homeassistant_entity_available == 0` | 15m |
    | `ZigbeeBatteryLow` | `homeassistant_sensor_battery_percent < 20` | 1h |
    | `Zigbee2MQTTBridgeOffline` | The bridge connection entity has state off (`homeassistant_binary_sensor_state == 0`) | 5m |
    | `HomeAssistantMetricsDown` | `up{job="hass"} == 0`, or the job is missing (`absent(...)`) | 10m |

11. `ZigbeeDeviceUnavailable` must send one alert per device, not one alert per entity. A device has
    many entities (battery, light level, motion, and so on). Group by a device-level label, or check
    only one entity per device (for example the battery sensor for battery devices, and the
    `light.*` or `switch.*` entity for mains devices).
12. `ZigbeeDeviceUnavailable` must not fire for `plug_4` and `plug_5`. Requirement 2 already
    prevents this. If it is not enough, exclude them in the rule too.
13. The rules must not depend on single entity names where a label can be used instead (for example
    `domain` or `device_class`), so that renaming a device does not break a rule. The bridge entity
    is an exception.

### D. Delivery

14. The alerts follow the normal Alertmanager routing. No new receiver or route is part of this
    work. Note: today `warning` alerts are dropped. They reach the owner's phone only after
    `tasks/prd-notifications-and-email.md` is done (see section 7).

## 5. Non-Goals (Out of Scope)

- No change to Alertmanager receivers or routes. That is part of the notifications PRD.
- No Grafana dashboards, and no metrics for dashboards (temperature, humidity, power use, car data).
  The filter in requirement 6 includes only what the alerts need.
- No alert for unstable devices (devices that leave and join the network often). HA does not have
  this data (`leave_count`, `network_address_changes` are only in Zigbee2MQTT's health message).
- No offline alert for the IKEA remotes. Their battery alert still works.
- No separate MQTT exporter. HA is the only source of Zigbee metrics.
- No alerts through HA's own notification system.
- No removal of `plug_4` and `plug_5` from Zigbee2MQTT.

## 6. Design Considerations

No user interface. The only "design" is the alert text. Each alert must answer: which device, what
is wrong, since when, and what to do first. Examples:

- `ZigbeeDeviceUnavailable`: "Zigbee device *motion sensor berging* is unavailable. It sent nothing
  for 4 hours or did not answer a check. Press its button. If that does not help, pair it again,
  through the Coordinator."
- `ZigbeeBatteryLow`: "Battery of *Sensor Attic* is at 18%. Change the battery."

## 7. Technical Considerations

- **Order of work:** Do section A first. Without it, HA never marks Zigbee devices as `unavailable`,
  and `ZigbeeDeviceUnavailable` can never fire.
- **Per-device Zigbee2MQTT settings:** Per-device settings are stored in `devices.yaml` on the
  Zigbee2MQTT volume. That file is written by Zigbee2MQTT and is not in Git. Check if the chart
  (`values.yaml`, which is merged into `configuration.yaml` by the `yq` init container) can hold a
  `devices:` section for the four devices in requirement 2 without overwriting the device list that
  Zigbee2MQTT manages. If not, set them in the Zigbee2MQTT web page and record the reason in the
  component's README.
- **HA configuration template:** The HA configuration is created from `configuration.templateConfig`
  in `values.yaml`. Add the `prometheus:` block there, not on the HA volume.
- **Duplicate bridge entities:** HA has two sets of Zigbee2MQTT bridge entities, for example
  `binary_sensor.zigbee2mqtt_bridge_connection_state` and `..._connection_state_2`. One set is
  probably left over from an old setup. Find out which set is live before writing
  `Zigbee2MQTTBridgeOffline`, and remove the old set if it is not used (see section 9).
- **HA as single point of failure:** If HA is down, no Zigbee alert can fire. `HomeAssistantMetricsDown`
  covers this.
- **Delivery depends on another PRD:** All alerts are `warning`. Until
  `tasks/prd-notifications-and-email.md` is done, Alertmanager drops them. They are still visible in
  Karma (the alert dashboard in `infrastructure/observability/karma`) and in the Prometheus web page.
- **Versions:** HA 2026.9.4 runs now. Check the metric names in the HA Prometheus integration
  documentation for that version (`homeassistant_entity_available`,
  `homeassistant_sensor_battery_percent`, `homeassistant_binary_sensor_state`).
- **Resources:** HA and Zigbee2MQTT already have resource settings. No new pod is added.

## 8. Success Metrics

1. Prometheus shows the HA target as up (`up{job="hass"} == 1`), and the metric
   `homeassistant_entity_available` exists for all Zigbee2MQTT devices.
2. **Offline test:** Take the battery out of one Aqara motion sensor. After the passive timeout
   (4 hours) plus 15 minutes, `ZigbeeDeviceUnavailable` is firing for that device, and only one
   alert is shown for it. When the battery is back and the sensor sends a message, the alert
   resolves.
3. **Mains test:** Turn off the power of one lamp or plug (not `plug_4` or `plug_5`). Within 30
   minutes, `ZigbeeDeviceUnavailable` is firing for it.
4. **Bridge test:** Stop Zigbee2MQTT (scale the StatefulSet to 0). Within 5 minutes,
   `Zigbee2MQTTBridgeOffline` is firing. Scale back to 1 and the alert resolves.
5. **HA test:** Stop HA, or make the token wrong. Within 10 minutes, `HomeAssistantMetricsDown` is
   firing.
6. No alert fires for `plug_4`, `plug_5`, `buttons - tv` or `Button Attic` being offline.
7. ArgoCD shows the `zigbee2mqtt` and `hass` apps as Synced and Healthy, with no drift.
8. `curl` to `https://<hass host>/api/prometheus` without a token returns 401.

## 9. Open Questions

1. Can the four per-device availability settings (requirement 2) be kept in Git, or must they be
   set in the Zigbee2MQTT web page?
2. Which of the two sets of Zigbee2MQTT bridge entities in HA is live, and can the other set be
   removed?
3. Is a 4-hour passive timeout right for all battery devices? The SONOFF climate sensors report
   often, so a shorter time is possible. The Aqara motion sensors send a status message about once
   per hour.
4. Must the HA token belong to a separate non-admin user? Check whether a non-admin user can read
   `/api/prometheus` in HA 2026.9.
5. Must `plug_4` and `plug_5` be removed from Zigbee2MQTT later? This PRD only excludes them.
