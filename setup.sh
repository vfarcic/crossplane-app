#!/bin/sh
set -e

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--margin "1 2" --padding "2 4" \
	'Setup for the explamples of the Crossplane Configuration
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
|Google Cloud CLI|If using Google Cloud|'https://cloud.google.com/sdk/docs/install'        |
" | gum format

gum confirm "
Do you have those tools installed?
" || exit 0

#################
# Prerequisites #
#################

gum confirm '
Do you have a Kubernetes cluster up-and-running?
' || exit 0

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

################
# Hyperscalers #
################

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

if [[ "$HYPERSCALER" != "none" ]]; then

    helm upgrade --install \
        external-secrets external-secrets \
        --repo https://charts.external-secrets.io \
        --namespace external-secrets --create-namespace --wait

fi

################
# Hyperscalers #
################

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









################
# Hyperscalers #
################

echo "
Which Hyperscaler do you want to use?"

HYPERSCALER=$(gum choose "google" "aws" "azure")

echo "export HYPERSCALER=$HYPERSCALER" >> .env

if [[ "$HYPERSCALER" == "azure" ]]; then
    gum style \
        --foreground 212 --border-foreground 212 --border double \
        --margin "1 2" --padding "2 4" \
        'Unfortunately, the demo currently does NOT work in Azure.' \
        '
Please let me know in the comments of the video if you would like
me to add the commands for Azure.' \
        '
I will do my best to add the commands if there is interest or you
can create a pull request if you would like to contribute.'

    exit 0
fi

###############
# GitHub Repo #
###############

echo
echo

GITHUB_ORG=$(gum input --placeholder "GitHub organization (do NOT use GitHub username)" --value "$GITHUB_ORG")
echo "export GITHUB_ORG=$GITHUB_ORG" >> .env

GITHUB_USER=$(gum input --placeholder "GitHub username" --value "$GITHUB_USER")
echo "export GITHUB_USER=$GITHUB_USER" >> .env

gum confirm "
Do you want to fork the vfarcic/idp-demo repository?
Choose \"No\" if you already forked it and it's merged with upstream.
" && gh repo fork vfarcic/idp-demo --clone --remote --org ${GITHUB_ORG}

cd idp-demo

gh repo set-default ${GITHUB_ORG}/idp-demo

cd ..

gum confirm "
We need to authorize GitHub CLI to manage your secrets.
Choose \"No\" if you already authorized it previously.
" && gh auth refresh --hostname github.com --scopes admin:org

gum confirm "
We need to create GitHub secret ORG_ADMIN_TOKEN.
Choose \"No\" if you already have it.
" \
    && ORG_ADMIN_TOKEN=$(gum input --placeholder "Please enter GitHub organization admin token." --password) \
    && gh secret set ORG_ADMIN_TOKEN --body "$ORG_ADMIN_TOKEN" --org ${GITHUB_ORG} --visibility all

DOCKERHUB_USER=$(gum input --placeholder "Please enter Docker Hub user")
echo "export DOCKERHUB_USER=$DOCKERHUB_USER" >> .env

gum confirm "
We need to create GitHub secret DOCKERHUB_USER.
Choose \"No\" if you already have it.
" \
    && gh secret set DOCKERHUB_USER --body "$DOCKERHUB_USER" --org ${GITHUB_ORG} --visibility all

gum confirm "
We need to create GitHub secret DOCKERHUB_TOKEN.
Choose \"No\" if you already have it.
" \
    && DOCKERHUB_TOKEN=$(gum input --placeholder "Please enter Docker Hub token (more info: https://docs.docker.com/docker-hub/access-tokens)." --password) \
    && gh secret set DOCKERHUB_TOKEN --body "$DOCKERHUB_TOKEN" --org ${GITHUB_ORG} --visibility all

export KUBECONFIG=$PWD/kubeconfig.yaml
echo "export KUBECONFIG=$KUBECONFIG" >> .env

################
# Hyperscalers #
################

if [[ "$HYPERSCALER" == "google" ]]; then

    export USE_GKE_GCLOUD_AUTH_PLUGIN=True

    export PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)
    echo "export PROJECT_ID=${PROJECT_ID}" >> .env

    gcloud projects create ${PROJECT_ID}

    echo "
Please open https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=${PROJECT_ID} in a browser and *ENABLE* the API."

    gum input --placeholder "
Press the enter key to continue."

    echo "
Please open https://console.cloud.google.com/apis/library/sqladmin.googleapis.com?project=${PROJECT_ID} in a browser and *ENABLE* the API."

    gum input --placeholder "
Press the enter key to continue."

    echo "
Please open https://console.cloud.google.com/marketplace/product/google/secretmanager.googleapis.com?project=${PROJECT_ID} in a browser and *ENABLE* the API."

    gum input --placeholder "
Press the enter key to continue."

    export SA_NAME=devops-toolkit

    export SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

    gcloud iam service-accounts create $SA_NAME --project ${PROJECT_ID}

    export ROLE=roles/admin

    gcloud projects add-iam-policy-binding --role $ROLE ${PROJECT_ID} --member serviceAccount:$SA

    gcloud iam service-accounts keys create gcp-creds.json --project ${PROJECT_ID} --iam-account $SA

    gcloud container clusters create dot --project ${PROJECT_ID} --region us-east1 --machine-type e2-standard-4 --num-nodes 1 --no-enable-autoupgrade --enable-autoscaling --min-nodes=1 --max-nodes=6

    gcloud container clusters get-credentials dot --project ${PROJECT_ID} --region us-east1

    gum spin --spinner line --title "Waiting for the cluster to be available..." -- sleep 30

    kubectl create namespace crossplane-system

    kubectl --namespace crossplane-system create secret generic gcp-creds --from-file creds=./gcp-creds.json

    gcloud iam service-accounts --project ${PROJECT_ID} create external-secrets

    echo '{"password": "YouWillNeverFindOut"}\c' | gcloud secrets --project ${PROJECT_ID} create production-postgresql --data-file=-

    gcloud secrets --project ${PROJECT_ID} add-iam-policy-binding production-postgresql --member "serviceAccount:external-secrets@${PROJECT_ID}.iam.gserviceaccount.com" --role "roles/secretmanager.secretAccessor"

    gcloud iam service-accounts --project ${PROJECT_ID} keys create account.json --iam-account=external-secrets@${PROJECT_ID}.iam.gserviceaccount.com

    kubectl create namespace external-secrets

    kubectl create namespace production

    kubectl --namespace production create secret generic google --from-file=credentials=account.json

    yq --inplace ".spec.provider.gcpsm.projectID = \"${PROJECT_ID}\"" idp-demo/eso/secret-store-google.yaml

elif [[ "$HYPERSCALER" == "aws" ]]; then

    cat idp-demo/scripts/create-repo-app-db.sh | sed -e "s@google@aws@g" | tee idp-demo/scripts/create-repo-app-db.sh.tmp
    mv idp-demo/scripts/create-repo-app-db.sh.tmp idp-demo/scripts/create-repo-app-db.sh
    cat idp-demo/argocd/port.yaml | sed -e "s@google@aws@g" | tee idp-demo/argocd/port.yaml.tmp
    mv idp-demo/argocd/port.yaml.tmp idp-demo/argocd/port.yaml
    cd idp-demo
    set +e
    git add .
    git commit -m "AWS"
    git push
    set -e
    cd ..

    echo

    AWS_ACCESS_KEY_ID=$(gum input --placeholder "AWS Access Key ID" --value "$AWS_ACCESS_KEY_ID")
    echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env
    
    AWS_SECRET_ACCESS_KEY=$(gum input --placeholder "AWS Secret Access Key" --value "$AWS_SECRET_ACCESS_KEY" --password)
    echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> .env

    AWS_ACCOUNT_ID=$(gum input --placeholder "AWS Account ID" --value "$AWS_ACCOUNT_ID")
    echo "export AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID" >> .env

    eksctl create cluster --config-file idp-demo/eksctl-config.yaml --kubeconfig $KUBECONFIG

    eksctl create addon --name aws-ebs-csi-driver --cluster dot --service-account-role-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole --force

    kubectl create namespace crossplane-system

    echo "[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
" >aws-creds.conf

    kubectl --namespace crossplane-system create secret generic aws-creds --from-file creds=./aws-creds.conf

    set +e
    aws secretsmanager create-secret --name production-postgresql --region us-east-1 --secret-string '{"password": "YouWillNeverFindOut"}'
    set -e

    kubectl create namespace external-secrets

    kubectl create namespace production

    kubectl --namespace production create secret generic aws --from-literal access-key-id=$AWS_ACCESS_KEY_ID --from-literal secret-access-key=$AWS_SECRET_ACCESS_KEY
else
    echo "Azure is NOT supported yet."
fi

##############
# Crossplane #
##############

helm repo add crossplane-stable https://charts.crossplane.io/stable

helm repo update

helm upgrade --install crossplane crossplane-stable/crossplane --namespace crossplane-system --create-namespace --wait

kubectl apply --filename idp-demo/crossplane-config/provider-kubernetes-incluster.yaml

kubectl apply --filename idp-demo/crossplane-config/provider-helm-incluster.yaml

kubectl wait --for=condition=healthy provider.pkg.crossplane.io --all --timeout=300s

kubectl apply --filename idp-demo/crossplane-config/config-sql.yaml

kubectl apply --filename idp-demo/crossplane-config/config-app.yaml

gum spin --spinner line --title "Waiting for GKE to stabilize (1 minute)..." -- sleep 60

kubectl wait --for=condition=healthy provider.pkg.crossplane.io --all --timeout=300s

if [[ "$HYPERSCALER" == "google" ]]; then
    echo "apiVersion: gcp.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  projectID: ${PROJECT_ID}
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: gcp-creds
      key: creds" \
    | kubectl apply --filename -
else
    kubectl apply --filename idp-demo/crossplane-config/provider-config-$HYPERSCALER-official.yaml
fi

#################
# Setup Traefik #
#################

helm upgrade --install traefik traefik --repo https://helm.traefik.io/traefik --namespace traefik --create-namespace --wait

if [[ "$HYPERSCALER" == "aws" ]]; then

    gum spin --spinner line --title "Waiting for the ELB DNS to propagate..." -- sleep 120

    INGRESS_HOSTNAME=$(kubectl --namespace traefik get service traefik --output jsonpath="{.status.loadBalancer.ingress[0].hostname}")

    INGRESS_HOST=$(dig +short $INGRESS_HOSTNAME | sed -n 1p) 

else

    INGRESS_HOST=$(kubectl --namespace traefik get service traefik --output jsonpath="{.status.loadBalancer.ingress[0].ip}")

fi

echo "export INGRESS_HOST=$INGRESS_HOST" >> .env

##############
# Kubernetes #
##############

yq --inplace ".server.ingress.hosts[0] = \"gitops.${INGRESS_HOST}.nip.io\"" idp-demo/argocd/helm-values.yaml

cd idp-demo

export REPO_URL=$(git config --get remote.origin.url)

cd ..

yq --inplace ".spec.source.repoURL = \"${REPO_URL}\"" idp-demo/argocd/apps.yaml

yq --inplace ".spec.source.repoURL = \"${REPO_URL}\"" idp-demo/argocd/schema-hero.yaml

kubectl apply --filename idp-demo/k8s/namespaces.yaml

########
# Port #
########

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--margin "1 2" --padding "2 4" \
	'1. Open https://app.getport.io in a browser

2. Register (if not already).

3. Click the  "+ Add" button, select  "Choose from template",
followed with  "Map your Kubernetes ecosystem".

4. Select the "Builder" page.

5. Click the  "Get this template" button, keep  "Are you using
ArgoCD" set to  "False", and click the  "Next" button, ignore
the instructions to run a script and click the "Done" button.'

gum input --placeholder "
Press the enter key to continue."

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--margin "1 2" --padding "2 4" \
	'Follow the instructions from
https://docs.getport.io/build-your-software-catalog/sync-data-to-catalog/git/github/self-hosted-installation#register-ports-github-app
to install the Port GitHub App.'

gum input --placeholder "
Press the enter key to continue."

##################
# GitHub Actions #
##################

yq --inplace ".on.workflow_dispatch.inputs.repo-user.default = \"${GITHUB_USER}\"" idp-demo/.github/workflows/create-app-db.yaml

yq --inplace ".on.workflow_dispatch.inputs.image-repo.default = \"docker.io/${DOCKERHUB_USER}\"" idp-demo/.github/workflows/create-app-db.yaml

cat idp-demo/port/backend-app-action.json \
    | jq ".userInputs.properties.\"repo-org\".default = \"$GITHUB_ORG\"" \
    | jq ".invocationMethod.org = \"$GITHUB_ORG\"" \
    > idp-demo/port/backend-app-action.json.tmp

mv idp-demo/port/backend-app-action.json.tmp idp-demo/port/backend-app-action.json

gh repo view --web $GITHUB_ORG/idp-demo

echo "
Open \"Actions\" and enable GitHub Actions."

gum input --placeholder "
Press the enter key to continue."

###########
# The End #
###########

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--margin "1 2" --padding "2 4" \
	'The setup is almost finished.' \
    '
Execute "source .env" to set the environment variables.'