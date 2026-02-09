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
* OpenBAO + External Secrets Operator

### Inpiration

* [k3s-argocd-starter](https://github.com/mitchross/k3s-argocd-starter/)
* [YT: Dreams of autonomy favorite homelab setup](https://www.youtube.com/watch?v=2yplBzPCghA)

## setup

### OpenBAO (Secret Management)

OpenBAO is used for secret management, with External Secrets Operator (ESO) syncing secrets to Kubernetes.

#### Unseal OpenBAO (after pod restart)

OpenBAO starts sealed. You need 3 of 5 unseal keys:

```sh
kubectl exec -n security openbao-0 -- bao operator unseal <unseal-key-1>
kubectl exec -n security openbao-0 -- bao operator unseal <unseal-key-2>
kubectl exec -n security openbao-0 -- bao operator unseal <unseal-key-3>
```

Check status:

```sh
kubectl exec -n security openbao-0 -- bao status
```

#### Add a secret

```sh
kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="<root-token>" && bao kv put kv/<path> <key>=<value>'
```

Example:

```sh
kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="hvs.xxx" && bao kv put kv/myapp password=supersecret api-key=abc123'
```

#### Read a secret

```sh
kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="<root-token>" && bao kv get kv/<path>'
```

#### List secrets

```sh
kubectl exec -n security openbao-0 -- sh -c 'export BAO_TOKEN="<root-token>" && bao kv list kv/'
```

#### Use secret in an application

Create an ExternalSecret in your app namespace:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-secrets
  namespace: myapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: myapp-secrets
  data:
    - secretKey: password
      remoteRef:
        key: myapp
        property: password
    - secretKey: api-key
      remoteRef:
        key: myapp
        property: api-key
```

ESO creates a Kubernetes Secret `myapp-secrets` that your pods can use.

#### Bootstrap ESO connection to OpenBAO (one-time setup)

After initializing OpenBAO, set up AppRole auth for ESO:

```sh
kubectl exec -it -n security openbao-0 -- sh
```

Inside the pod:

```sh
export BAO_TOKEN="<root-token>"

# Enable KV v2 secrets engine
bao secrets enable -path=kv kv-v2

# Enable AppRole auth
bao auth enable approle

# Create policy for ESO (read-only)
bao policy write eso-policy - <<EOF
path "kv/data/*" {
  capabilities = ["read"]
}
path "kv/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

# Create AppRole
bao write auth/approle/role/eso \
  token_policies="eso-policy" \
  token_ttl=1h \
  token_max_ttl=4h

# Get credentials (save these!)
bao read auth/approle/role/eso/role-id
bao write -f auth/approle/role/eso/secret-id
```

Create the bootstrap secret (only manual secret needed):

```sh
kubectl create secret generic openbao-approle \
  --namespace security \
  --from-literal=role-id=<role-id> \
  --from-literal=secret-id=<secret-id>
```

The ClusterSecretStore is deployed via GitOps and references this secret.

#### Verify ESO connection

```sh
kubectl get clustersecretstore openbao
```

Should show `Ready: True`.

### Sealed secrets (legacy)

> **Note**: Sealed secrets is being replaced by OpenBAO + ESO.

To store a yaml document in a secret, create document.yaml first, like:

```sh
name: foo
pass: bar
key: [2,3,4,5]
```

The following command takes the contents of document.yaml and stores it in a secret under the key "secret.yaml". The name of the secret will be myNewSecret.
```sh
kubectl create secret generic myNewSecret --from-file=secret.yaml=document.yaml -o yaml > secret.yaml
```

Seal the secret:

```sh
cat secret.yaml | kubeseal --controller-namespace kube-system --controller-name sealed-secrets -o yaml
```

Show secret without what is added by the cluster and frameworks:

```sh
kubectl get secrets zigbee2mqtt -o yaml | yq eval-all 'del(.metadata.annotations, .metadata.labels, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid)'
```

This secret can be piped into sealedsecrets:

```sh
kubectl get secrets zigbee2mqtt -o yaml | yq eval-all 'del(.metadata.annotations, .metadata.labels, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid)' | kubeseal --controller-namespace kube-system --controller-name sealed-secrets -o yaml
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
  -f infrastructure/networking/cilium/values.yaml \
  --version 1.17.6 \
  --set operator.replicas=1
```

The cilium files in this repository contain the proper values for my setup.

### ArgoCD

I installed all the required binaries on my workstation and install from there.

```sh
# Argo CD Bootstrap
kubectl create namespace argocd
kubectl kustomize --enable-helm infrastructure/controllers/argocd | kubectl apply -f -
kubectl apply -f infrastructure/controllers/argocd/projects.yaml

# Obtain argocd web interface initial password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

### cert-manager

### democratic-cli
