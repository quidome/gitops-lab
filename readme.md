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

## setup

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
