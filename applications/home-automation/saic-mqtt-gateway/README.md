# SAIC MQTT Gateway

MQTT gateway for SAIC iSmart API integration, enabling vehicle data publishing to MQTT and A Better Route Planner (ABRP).

## Configuration

### Secrets Management

All secrets are stored in OpenBao at: `kv/home-automation/saic-mqtt-gateway`

### Required Secrets

#### SAIC iSmart API Credentials
- `SAIC_USER` - Your SAIC iSmart account username/email
- `SAIC_PASSWORD` - Your SAIC iSmart account password

#### ABRP Integration (Optional)

To enable A Better Route Planner telemetry:

**Required:**
- `ABRP_USER_TOKEN` - Your ABRP user token mapped to your vehicle VIN

**How to obtain:**
1. Log in to [A Better Route Planner](https://abetterrouteplanner.com)
2. Navigate to **Settings → Live Data** (or **Settings → OBD**)
3. Find the **Generic** integration section
4. Copy your user token

**Format:**
```
VIN=token
```

**Example:**
```bash
kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="<root-token>" && \
  bao kv put kv/home-automation/saic-mqtt-gateway \
    ABRP_USER_TOKEN="LSJXXXX12345=a1b2c3d4-e5f6-7890-abcd-ef1234567890"'
```

For multiple vehicles:
```
VIN1=token1,VIN2=token2
```

**Note:** The ABRP_API_KEY uses the default open-source telemetry API key and does not need to be configured.

## Deployment

Deployed via Helmfile with custom Helm chart:
- Chart location: `./helm-chart`
- Namespace: `home-automation`
- MQTT broker: `tcp://mosquitto.home-automation.svc.cluster.local:1883`

### Adding Secrets

```bash
# Add or update secrets in OpenBao
kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="<root-token>" && \
  bao kv put kv/home-automation/saic-mqtt-gateway \
    SAIC_USER="your-email@example.com" \
    SAIC_PASSWORD="your-password" \
    ABRP_USER_TOKEN="LSJXXXX=your-token"'

# Verify secrets
kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="<root-token>" && \
  bao kv get kv/home-automation/saic-mqtt-gateway'
```

The ExternalSecret will automatically sync changes within 1 hour (or force refresh by deleting the pod).
