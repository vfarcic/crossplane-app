## Prerequisites

```bash
# Create a Kubernetes cluster

helm upgrade --install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system --create-namespace --wait

kubectl apply --filename dependencies

sleep 2

kubectl wait --for=condition=healthy provider.pkg.crossplane.io \
    --all --timeout=300s

kubectl apply --filename config.yaml

sleep 10

kubectl wait --for=condition=healthy provider.pkg.crossplane.io \
    --all --timeout=300s
```
