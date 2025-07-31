# Democratic CSO

Democratic is now deployed by argocd.
It took a while to come to a working setup, mainly because of mistakes I made.

The most important one is about the iscsi values file:

```yaml
driver:
  existingConfigSecret: "truenas-iscsi-driver-config"
```
The value of `existingConfigSecret` should be the name of a secret, not 'true'.

It took me a while to figure that out.

Next to that, generating the contents of the sealed secret took me a while as well.
I was unaware that the default settings for a sealed secret are that the secret can only be unlocked if the namespace and the secret name match.
Both are also contained in the encrypted part.

## Generate new sealed secret for driver config

Easiest is to use the `driver.config` content from the values file.

```sh
# Pick the useful part from values.yaml
cat truenas-api-iscsi/values.yaml | yq '.driver.config' > driver-config-file.yaml

# edit the file as needed
# create a new secret
kubectl create secret generic tmp-secret --from-file driver-config-file.yaml

# pull key
kubectl get secrets tmp-secret -o yaml | rg -v 'uid|creationTimestamp|resourceVersion' > new-secret.yaml

# Edit the file to set name and namespace to what they need to be
# Create a sealed secret
cat new-secret.yaml | kubeseal --controller-namespace kube-system --controller-name sealed-secrets -o yaml > truenas-api-iscsi/driver-config-file.yaml

# Clean up
rm driver-config-file.yaml
kubectl delete secret tmp-secret
```
