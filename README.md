## Prerequisites

```bash
# Create a Kubernetes cluster with an Ingress controller

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

# Execute only if using databases in Cloud (e.g., Google Cloud,
#   AWS, Azure, etc.).
helm upgrade --install \
    external-secrets external-secrets \
    --repo https://charts.external-secrets.io \
    --namespace external-secrets --create-namespace --wait
```

## Create Apps

* [ Create App With PostgreSQL In Google Cloud](docs/google-cloud.md)

