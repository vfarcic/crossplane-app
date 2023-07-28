## Prerequisites

```bash
# Create a Kubernetes cluster

helm upgrade --install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system --create-namespace --wait
```
