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

### Inpiration

* [k3s-argocd-starter](https://github.com/mitchross/k3s-argocd-starter/)
* [YT: Dreams of autonomy favorite homelab setup](https://www.youtube.com/watch?v=2yplBzPCghA)

## Namespace Organization

| Namespace | Components | Purpose |
|-----------|------------|---------|
| `kube-system` | cilium, cert-manager, sealed-secrets, node-feature-discovery, metrics-server, coredns | Core cluster infrastructure and system services |
| `argocd` | ArgoCD | GitOps controller |
| `storage` | democratic-csi (truenas-iscsi, truenas-nfs) | Storage provisioning |
| `networking` | gateway, pihole, external-dns | Network services and ingress |
| `syncthing` | syncthing | File synchronization |
| `zigbee2mqtt` | zigbee2mqtt | Home automation gateway |
| Individual app namespaces | bazarr, prowlarr, radarr, sonarr, sabnzbd, qbittorrent, spotweb | Media/download applications (isolated for security/management) |

## Restore Guide

If the cluster is broken, follow this restore order:

### Phase 1: Core Infrastructure

1. **Cilium** (CNI - required for all networking)
   ```sh
   helm repo add cilium https://helm.cilium.io && helm repo update
   helm install cilium cilium/cilium -n kube-system \
     -f infrastructure-legacy/networking/cilium/values.yaml \
     --version 1.18.6 \
     --set operator.replicas=3
   ```

2. **Sealed-secrets** (required for encrypted secrets)
   ```sh
   kubectl create namespace kube-system
   kubectl kustomize --enable-helm infrastructure-legacy/controllers/sealed-secrets | kubectl apply -f -
   ```

3. **Democratic-csi** (storage - requires secrets)
   - Ensure TrueNAS credentials are available as SealedSecrets
   - Deploy to `storage` namespace:
   ```sh
   kubectl create namespace storage
   kubectl kustomize --enable-helm infrastructure-legacy/storage/democratic-csi | kubectl apply -f -
   ```

4. **Cert-manager** (TLS certificates)
   ```sh
   kubectl kustomize --enable-helm infrastructure-legacy/controllers/cert-manager | kubectl apply -f -
   ```

### Phase 2: ArgoCD

5. **ArgoCD** (GitOps automation)
   ```sh
   kubectl create namespace argocd
   kubectl kustomize --enable-helm infrastructure-legacy/controllers/argocd | kubectl apply -f -
   kubectl apply -f infrastructure-legacy/applicationset.yaml
   kubectl apply -f applications-legacy/applicationset.yaml
   ```

### Phase 3: Networking

6. **Gateway, Pihole, External-DNS**
   ```sh
   kubectl kustomize --enable-helm infrastructure-legacy/networking/gateway | kubectl apply -f -
   kubectl kustomize --enable-helm infrastructure-legacy/networking/pihole | kubectl apply -f -
   kubectl kustomize --enable-helm infrastructure-legacy/networking/external-dns | kubectl apply -f -
   ```

### Important Notes

- **ApplicationSet paths**: When restoring, ensure ApplicationSets point to `infrastructure-legacy/` and `applications-legacy/` directories
- **SealedSecrets**: Must be created before resources that depend on them
- **Cilium first**: Everything depends on networking working
- **Cleanup**: Delete empty/deprecated namespaces after restore (democratic-csi, cilium-test-1, etc.)

## setup

### Sealed secrets

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
  -f infrastructure-legacy/networking/cilium/values.yaml \
  --version 1.18.6 \
  --set operator.replicas=3
```

The cilium files in this repository contain the proper values for my setup.

### ArgoCD

I installed all the required binaries on my workstation and install from there.

```sh
# Argo CD Bootstrap
kubectl create namespace argocd
kubectl kustomize --enable-helm infrastructure-legacy/controllers/argocd | kubectl apply -f -
kubectl apply -f infrastructure-legacy/applicationset.yaml
kubectl apply -f applications-legacy/applicationset.yaml

# Obtain argocd web interface initial password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

### cert-manager

Manages TLS certificates using Cloudflare DNS and Let's Encrypt.

**Configuration:**
- ClusterIssuer: `cloudflare-cluster-issuer` in `kube-system` namespace
- DNS provider: Cloudflare (API token stored as SealedSecret)
- ACME server: Let's Encrypt (production)
- Email: quidome@gmail.com

**Deploy:**
```sh
kubectl kustomize --enable-helm infrastructure-legacy/controllers/cert-manager | kubectl apply -f -
```

**Create new certificate:**
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-tls
  namespace: default
spec:
  secretName: example-tls
  issuerRef:
    name: cloudflare-cluster-issuer
    kind: ClusterIssuer
  dnsNames:
    - example.domain.com
```

**Check certificate status:**
```sh
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>
```

### democratic-csi

CSI driver for TrueNAS storage (iSCSI and NFS).

**Configuration:**
- Namespace: `storage`
- Storage backends:
  - `truenas-iscsi`: Block storage via iSCSI
  - `truenas-nfs`: File storage via NFS
- StorageClasses created:
  - `truenas-iscsi` (default)
  - `truenas-nfs`

**Deploy:**
```sh
kubectl create namespace storage
kubectl kustomize --enable-helm infrastructure-legacy/storage/democratic-csi | kubectl apply -f -
```

**Requirements:**
- TrueNAS credentials as SealedSecrets in `storage` namespace:
  - `truenas-iscsi-driver-config`
  - `truenas-nfs-driver-config`
- iscsi-initiator-utils installed on all nodes (NixOS: `openiscsi` package)

**Usage example:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: example-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: truenas-iscsi
  resources:
    requests:
      storage: 10Gi
```

### gateway

Kubernetes Gateway API for ingress routing.

**Deploy:**
```sh
kubectl kustomize --enable-helm infrastructure-legacy/networking/gateway | kubectl apply -f -
```

**Components:**
- GatewayClass: `cilium`
- Gateway: `gateway-internal` in `networking` namespace (IP: 172.16.40.50)
- Internal services routed via `gw-internal.yaml`
- Certificates managed by cert-manager

**Note:** Gateway resources are now in `networking` namespace alongside pihole and external-dns.

### pihole

DNS ad-blocker and DHCP server.

**Deploy:**
```sh
kubectl kustomize --enable-helm infrastructure-legacy/networking/pihole | kubectl apply -f -
```

**Namespace:** `networking`

**Access:**
- Web UI: http://pihole.quido.me (via Gateway)
- DNS: pihole.networking:53

**Configuration:**
- Values in `infrastructure-legacy/networking/pihole/values.yaml`
- Custom DNS entries via ConfigMap

### external-dns

Synchronizes Kubernetes services with DNS providers.

**Deploy:**
```sh
kubectl kustomize --enable-helm infrastructure-legacy/networking/external-dns | kubectl apply -f -
```

**Namespace:** `networking`

**Configuration:**
- Provider: Cloudflare
- Source: pihole (DNS entries from pihole)
- Policy: sync (creates/updates DNS records)

**Check sync status:**
```sh
kubectl get endpointslice -n networking
kubectl logs -n networking deployment/external-dns
```

### democratic-cli

