# SAIC MQTT Gateway

MQTT gateway for SAIC iSmart API integration, enabling vehicle data publishing to MQTT and A Better Route Planner (ABRP).

## Configuration

### Secrets Management

Secrets are stored in Vault at: `kv/home-automation/saic-mqtt-gateway`

**Method:** Helmfile + Vals (deploy-time secret injection)

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
export ROOT_TOKEN="<your-root-token>"

kubectl exec -n security vault-0 -- sh -c "
export VAULT_TOKEN=\"$ROOT_TOKEN\"

vault kv patch kv/home-automation/saic-mqtt-gateway \
  ABRP_USER_TOKEN='LSJXXXX12345=a1b2c3d4-e5f6-7890-abcd-ef1234567890'
"
```

Or use the Vault UI at http://vault.quido.me to edit the `ABRP_USER_TOKEN` key.

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

### Adding/Updating Secrets

**Via Vault UI** (recommended):
1. Navigate to http://vault.quido.me
2. Login with your token
3. Go to `kv/home-automation/saic-mqtt-gateway`
4. Add or edit keys: `SAIC_USER`, `SAIC_PASSWORD`, `MQTT_USER`, `MQTT_PASSWORD`, `ABRP_USER_TOKEN`

**Via CLI:**
```bash
export ROOT_TOKEN="<your-root-token>"

# Add or update secrets in Vault
kubectl exec -n security vault-0 -- sh -c "
export VAULT_TOKEN=\"$ROOT_TOKEN\"

vault kv put kv/home-automation/saic-mqtt-gateway \
  SAIC_USER='your-email@example.com' \
  SAIC_PASSWORD='your-password' \
  MQTT_USER='saic' \
  MQTT_PASSWORD='your-mqtt-password' \
  ABRP_USER_TOKEN='LSJXXXX=your-token'
"

# Verify secrets
kubectl exec -n security vault-0 -- sh -c "
export VAULT_TOKEN=\"$ROOT_TOKEN\"
vault kv get kv/home-automation/saic-mqtt-gateway
"
```

**To apply changes:**
```bash
# Trigger ArgoCD sync (fetches new values from Vault)
argocd app sync home-automation-saic-mqtt-gateway

# Or manually
cd applications/home-automation/saic-mqtt-gateway
helmfile apply
```

Changes take effect on next deployment (Vals fetches at deploy-time, not runtime).
