# Democratic CSO

I don't know how to deploy democratic with argocd.
Until I figure it out, I'll stick to manual deployments.

## Install / upgrade with config changes

With every run, the `driver.config` secret gets overwritten.
I don't want to store my api key in `values.yaml`, which makes this process annoying for me.

With the command below, the config gets overwritten.

```sh
# set variables
API_KEY='Enter your api key here'
API_HOST='Enter your api host address here'

helm upgrade \
  --install \
  --values truenas-api-iscsi/values.yaml \
  --namespace democratic-csi \
  --set driver.config.httpConnection.apiKey=$API_KEY \
  --set driver.config.httpConnection.host=$API_HOST \
  --set driver.config.iscsi.targetPortal="$API_HOST:3260" \
  truenas-iscsi democratic-csi/democratic-csi
```

## Upgrade without config changes

The following command uses a setting that prevents the `driver.config` to be overwritten.

```sh
helm upgrade \
  --values truenas-api-iscsi/values.yaml \
  --namespace democratic-csi \
  --set driver.existingConfigSecret='true' \
  truenas-iscsi democratic-csi/democratic-csi
```

Be aware that for `existingConfigSecret`, `true` must be quoted.
