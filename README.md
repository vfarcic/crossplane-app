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

## Google Cloud Prerequisites (Optional)

```bash
export PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)

gcloud projects create $PROJECT_ID

echo "https://console.cloud.google.com/billing/enable?project=$PROJECT_ID"

# Open the URL from he output in a browser and set the billing account

echo "https://console.cloud.google.com/apis/library/sqladmin.googleapis.com?project=$PROJECT_ID"

# Open the URL from he output in a browser and *ENABLE* the API.

export SA_NAME=devops-toolkit

export SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create $SA_NAME \
    --project ${PROJECT_ID}

export ROLE=roles/admin

gcloud projects add-iam-policy-binding \
    --role $ROLE ${PROJECT_ID} --member serviceAccount:$SA

gcloud iam service-accounts keys create gcp-creds.json \
    --project ${PROJECT_ID} --iam-account $SA

kubectl --namespace crossplane-system \
    create secret generic gcp-creds \
    --from-file creds=./gcp-creds.json

echo "apiVersion: gcp.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
    argocd.argoproj.io/hook: PostSync
spec:
  projectID: $PROJECT_ID
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: gcp-creds
      key: creds" \
    | kubectl apply --filename -
```

## Create App With PostgreSQL In Google Cloud

```bash
kubectl create namespace a-team

kubectl --namespace a-team apply \
    --filename examples/backend-db-google.yaml
```