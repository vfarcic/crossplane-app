#!/bin/sh
set -e

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--margin "1 2" --padding "2 4" \
	'Setup for the examples of the Crossplane Configuration
    "dot-application".' 

gum confirm '
Are you ready to start?
Feel free to say "No" and inspect the script if you prefer setting up resources manually.
' || exit 0

rm -f .env

################
# Requirements #
################

echo "
## You will need following tools installed:
|Name            |Required             |More info                                          |
|----------------|---------------------|---------------------------------------------------|
|helm            |Yes                  |'https://helm.sh/docs/intro/install/'              |
|kubectl         |Yes                  |'https://kubernetes.io/docs/tasks/tools/#kubectl'  |
|yq              |Yes                  |'https://github.com/mikefarah/yq#install'          |
|Google Cloud CLI|If using Google Cloud|'https://cloud.google.com/sdk/docs/install'        |
" | gum format

gum confirm "
Do you have those tools installed?
" || exit 0

gum confirm '
Do you have a Kubernetes cluster with an ingress controller
  up-and-running?
' || exit 0

echo "
Which Hyperscaler do you want to use?"

HYPERSCALER=$(gum choose "google" "aws" "azure" "none")

echo "export HYPERSCALER=$HYPERSCALER" >> .env

# TODO: Remove once other hyperscalers are supported
if [[ "$HYPERSCALER" != "google" ]]; then

    gum style \
        --foreground 212 --border-foreground 212 --border double \
        --margin "1 2" --padding "2 4" \
        'Right now, the script supports only Google Cloud.
Please open an issue if you would like me (or you) to add support
for other hyperscalers.' 

    exit 0

fi

kubectl create namespace a-team

export INGRESS_CLASS=$(kubectl get ingressclasses \
    --output jsonpath="{.items[0].metadata.name}")

INGRESS_HOST=$(gum input --placeholder "What is the external IP of the Ingress service" --value "127.0.0.1")
echo "export INGRESS_HOST=$INGRESS_HOST" >> .env

yq --inplace \
    ".spec.parameters.host = \"silly-demo.$INGRESS_HOST.nip.io\"" \
    examples/backend-db-google.yaml

###################################
# External Secrets Operator (ESO) #
###################################

if [[ "$HYPERSCALER" != "none" ]]; then

    helm upgrade --install \
        external-secrets external-secrets \
        --repo https://charts.external-secrets.io \
        --namespace external-secrets --create-namespace --wait

fi

##############
# Crossplane #
##############

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

############################
# Crossplane: Hyperscalers #
############################

if [[ "$HYPERSCALER" == "google" ]]; then

    export PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)
    echo "export PROJECT_ID=${PROJECT_ID}" >> .env

    gcloud projects create ${PROJECT_ID}

    echo "
Please open https://console.cloud.google.com/billing/enable?project=${PROJECT_ID} in a browser and set the billing account."

        gum input --placeholder "
Press the enter key to continue."

    echo "
Please open https://console.cloud.google.com/apis/library/sqladmin.googleapis.com?project=${PROJECT_ID} in a browser and ENABLE* the API."

        gum input --placeholder "
Press the enter key to continue."

    echo "
Please open https://console.cloud.google.com/marketplace/product/google/secretmanager.googleapis.com?project=${PROJECT_ID} in a browser and ENABLE* the API."

        gum input --placeholder "
Press the enter key to continue."

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

    gcloud iam service-accounts --project ${PROJECT_ID} \
        create external-secrets

    echo '{"password": "YouWillNeverFindOut"}\c' \
        | gcloud secrets --project ${PROJECT_ID} \
        create production-postgresql --data-file=-

    gcloud secrets --project ${PROJECT_ID} \
        add-iam-policy-binding production-postgresql \
        --member "serviceAccount:external-secrets@${PROJECT_ID}.iam.gserviceaccount.com" \
        --role "roles/secretmanager.secretAccessor"

    gcloud iam service-accounts --project ${PROJECT_ID} \
        keys create account.json \
        --iam-account=external-secrets@${PROJECT_ID}.iam.gserviceaccount.com

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
  projectID: ${PROJECT_ID}
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
      projectID: ${PROJECT_ID}" \
    | kubectl apply --filename -

fi
