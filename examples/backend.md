## Setup

```sh
devbox shell

kind create cluster

helm upgrade --install crossplane crossplane \
    --repo https://charts.crossplane.io/stable \
    --namespace crossplane-system --create-namespace --wait

kubectl apply --filename config.yaml
```

TODO: Add the rest of the setup

## Example

TODO: Add an example

## Destroy

TODO: Add destroy