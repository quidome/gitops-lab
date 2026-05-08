# Gitops Lab

## Description

These are my notes from building this k3s home setup.

Core of the setup:

* Nixos
* k3s
* Cilium
* ArgoCD
* cert-manager
* democratic-csi
* Vault + Vals (deploy-time secret injection)

### Inpiration

* [k3s-argocd-starter](https://github.com/mitchross/k3s-argocd-starter/)
* [YT: Dreams of autonomy favorite homelab setup](https://www.youtube.com/watch?v=2yplBzPCghA)

## Project layout

- `docs/` — process/workflow documentation (audit, backlog, checklists, experiments, specs, stories, tasks, adrs)
- `.pi/skills/` — reusable Pi skills
- `.pi/prompts/` — prompt templates (slash commands)
- `.pi/extensions/` — custom TypeScript commands/tools

## setup

### Vault (Secret Management)

Vault is used for secret management, and secrets are injected at deploy-time via Vals in Helmfile.

Primary reference: `infrastructure/security/vault/VALS-SETUP.md`

#### Add/update a secret

```sh
vault kv put kv/<realm>/<application> <key>=<value>
```

Example:

```sh
vault kv put kv/home-automation/mosquitto passwordfile='user1:$7$...'
```

#### Read/list secrets

```sh
vault kv get kv/<realm>/<application>
vault kv list kv/<realm>
```

#### Use secret in an application (Helmfile + Vals)

```yaml
# helmfile.yaml.gotmpl
releases:
  - name: my-app
    values:
      - secretValue: {{ fetchSecretValue "ref+vault://kv/realm/app#KEY" | quote }}
```

#### Trigger sync after secret changes

```sh
kubectl patch application <app-name> -n gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

### Nixos

The key elements to make this setup work are in the snipper below.

```nix
environment.systemPackages = with pkgs; [
  openiscsi
  nfs-utils
];

networking.firewall.enable = false;

services.k3s = {
  enable = true;
  role = "server";
  clusterInit = true;
  token = "GENERATE_TOKEN";
  extraFlags = [
    "--disable=traefik,local-storage,metrics-server,servicelb,traefik"
    "--flannel-backend='none'"
    "--disable-network-policy"
    "--disable-cloud-controller"
    "--disable-kube-proxy"
  ];
};

services.openiscsi = {
  enable = true;
  name = "iqn.2016-04.com.open-iscsi:${config.networking.hostName}";
};

systemd.tmpfiles.rules = [
  "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  "L+ /usr/local/sbin - - - - /run/current-system/sw/sbin/"
];
```

### Cilium

I installed all the required binaries on my workstation and install from there.

```sh
# Add cilium chart repository and update before installing
helm repo add cilium https://helm.cilium.io && helm repo update
helm install cilium cilium/cilium -n kube-system \
  -f infrastructure/kube-system/cilium/values.yaml \
  --version 1.19.3 \
  --set operator.replicas=1
```

The cilium files in this repository contain the proper values for my setup.

Verify live Cilium version:
```sh
kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### ArgoCD

I installed all the required binaries on my workstation and install from there.

```sh
# Argo CD Bootstrap (chart version pinned in helmfile: 9.5.12)
kubectl create namespace gitops
helmfile -f infrastructure/gitops/argocd/helmfile.yaml apply
kubectl apply -f infrastructure/applicationset.yaml

# Check ArgoCD server deployment
kubectl get deploy -n gitops argocd-server

# Verify live ArgoCD version
kubectl -n gitops get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}'
```


## Applications

### Home Automation

#### Mosquitto (MQTT Broker)

Deployed via Helmfile using the k8sonlab chart. Exposed internally as a `ClusterIP` service on port `1883`.

**Generate password hash:**
```sh
docker run --rm eclipse-mosquitto mosquitto_passwd -c -b /dev/stdout <username> <password>
```

**Store passwordfile in Vault:**
```sh
vault kv put kv/home-automation/mosquitto passwordfile="user1:\$7\$101\$...
user2:\$7\$101\$..."
```

#### SAIC MQTT Gateway

Custom Helm chart for the SAIC iSmart MQTT gateway. Connects to Mosquitto and ABRP.

**Store secrets in Vault:**
```sh
vault kv put kv/home-automation/saic-mqtt-gateway \
  SAIC_USER="<user>" \
  SAIC_PASSWORD="<password>" \
  MQTT_USER="saic" \
  MQTT_PASSWORD="<mqtt-password>" \
  ABRP_API_KEY="<api-key>" \
  ABRP_USER_TOKEN="<token>"
```

#### Zigbee2MQTT

Zigbee2MQTT is **not** exposed as its own `Service` type `LoadBalancer`.

- Service type is `ClusterIP`
- External access is via `HTTPRoute` (`zigbee2mqtt.quido.me`) through `gateway-internal` (LoadBalancer IP `172.16.40.50`)
