## Google Cloud Prerequisites

```bash
export PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)

gcloud projects create $PROJECT_ID

echo "https://console.cloud.google.com/billing/enable?project=$PROJECT_ID"

# Open the URL from he output in a browser and set the billing account

echo "https://console.cloud.google.com/apis/library/sqladmin.googleapis.com?project=$PROJECT_ID"

# Open the URL from he output in a browser and *ENABLE* the API.

echo "https://console.cloud.google.com/marketplace/product/google/secretmanager.googleapis.com?project=$PROJECT_ID" 

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

gcloud iam service-accounts --project $PROJECT_ID \
    create external-secrets

echo '{"password": "YouWillNeverFindOut"}\c' \
    | gcloud secrets --project ${PROJECT_ID} \
    create production-postgresql --data-file=-

gcloud secrets --project $PROJECT_ID \
    add-iam-policy-binding production-postgresql \
    --member "serviceAccount:external-secrets@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role "roles/secretmanager.secretAccessor"

gcloud iam service-accounts --project $PROJECT_ID \
    keys create account.json \
    --iam-account=external-secrets@$PROJECT_ID.iam.gserviceaccount.com

kubectl --namespace external-secrets \
    create secret generic google \
    --from-file=credentials=account.json

echo "
apiVersion: gcp.upbound.io/v1beta1
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

echo "
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: google
spec:
  provider:
    gcpsm:
      auth:
        secretRef:
          secretAccessKeySecretRef:
            name: google
            key: credentials
            namespace: external-secrets
      projectID: $PROJECT_ID" \
    | kubectl apply --filename -
```

## Create App With PostgreSQL In Google Cloud

```bash
cat examples/backend-db-google.yaml

kubectl create namespace a-team

kubectl --namespace a-team apply \
    --filename examples/backend-db-google.yaml

kubectl --namespace a-team get appclaims

kubectl get sqls,managed

curl silly-demo.127.0.0.1.nip.io/videos
```

## Destroy

```bash
gcloud projects delete $PROJECT_ID
```