#!/usr/bin/env nu

# Installs and configures Crossplane with optional cloud provider setup
#
# Examples:
# > main apply crossplane --provider aws
# > main apply crossplane --provider google --app
# > main apply crossplane --provider azure --db --github --github_user user --github_token token
def --env "main apply crossplane" [
    --provider = none,      # Which provider to use. Available options are `none`, `google`, `aws`, and `azure`
    --app = false,          # Whether to apply DOT App Configuration
    --db = false,           # Whether to apply DOT SQL Configuration
    --github = false,       # Whether to apply DOT GitHub Configuration
    --github_user: string,  # GitHub user required for the DOT GitHub Configuration and optinal for the DOT App Configuration
    --github_token: string, # GitHub token required for the DOT GitHub Configuration and optinal for the DOT App Configuration
    --policies = false      # Whether to create Validating ADmission Policies
    --skip_login = false    # Whether to skip the login (only for Azure)
    --preview = false       # Whether to use the preview version of Crossplane
] {

    print $"\nInstalling (ansi yellow_bold)Crossplane(ansi reset)...\n"

    helm repo add crossplane https://charts.crossplane.io/stable

    helm repo add crossplane-preview https://charts.crossplane.io/preview

    helm repo update

    if $preview {

        (
            helm upgrade --install crossplane "crossplane-preview/crossplane"
                --namespace crossplane-system --create-namespace
                --set args='{"--enable-usages"}'
                --wait --devel
        )
    
    } else {

        (
            helm upgrade --install crossplane "crossplane/crossplane"
                --namespace crossplane-system --create-namespace
                --set args='{"--enable-usages"}'
                --wait
        )

    }

    mut provider_data = {}
    if $provider == "google" {
        $provider_data = setup google
    } else if $provider == "aws" {
        setup aws
    } else if $provider == "azure" {
        setup azure --skip_login $skip_login
    } else if $provider == "upcloud" {
        setup upcloud
    }

    if $app {

        print $"\n(ansi yellow_bold)Applying `dot-application` Configuration...(ansi reset)\n"

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Configuration"
            metadata: { name: "crossplane-app" }
            spec: { package: "xpkg.upbound.io/devops-toolkit/dot-application:v0.7.30" }
        } | to yaml | kubectl apply --filename -

        if $policies {

            {
                apiVersion: "admissionregistration.k8s.io/v1"
                kind: "ValidatingAdmissionPolicy"
                metadata: { name: "dot-app" }
                spec: {
                    failurePolicy: "Fail"
                    matchConstraints: {
                        resourceRules: [{
                            apiGroups:   ["devopstoolkit.live"]
                            apiVersions: ["*"]
                            operations:  ["CREATE", "UPDATE"]
                            resources:   ["appclaims"]
                        }]
                    }
                    validations: [
                        {
                            expression: "has(object.spec.parameters.scaling) && has(object.spec.parameters.scaling.enabled) && object.spec.parameters.scaling.enabled"
                            message: "`spec.parameters.scaling.enabled` must be set to `true`."
                        }, {
                            expression: "has(object.spec.parameters.scaling) && object.spec.parameters.scaling.min > 1"
                            message: "`spec.parameters.scaling.min` must be greater than `1`."
                        }
                    ]
                }
            } | to yaml | kubectl apply --filename -

            {
                apiVersion: "admissionregistration.k8s.io/v1"
                kind: "ValidatingAdmissionPolicyBinding"
                metadata: { name: "dot-app" }
                spec: {
                    policyName: "dot-app"
                    validationActions: ["Deny"]
                }
            } | to yaml | kubectl apply --filename -

        }

    }

    if $db {

        print $"\n(ansi yellow_bold)Applying `dot-sql` Configuration...(ansi reset)\n"

        if $provider == "google" {
            
            start $"https://console.cloud.google.com/marketplace/product/google/sqladmin.googleapis.com?project=($provider_data.project_id)"
            
            print $"\n(ansi yellow_bold)ENABLE(ansi reset) the API.\nPress any key to continue.\n"
            input

        }

        mut dot_sql_version = "v2.1.8"
        if not $preview {
            $dot_sql_version = "v1.1.21"
        }

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Configuration"
            metadata: { name: "crossplane-sql" }
            spec: { package: $"xpkg.upbound.io/devops-toolkit/dot-sql:($dot_sql_version)" }
        } | to yaml | kubectl apply --filename -

    }

    if $github {

        print $"\n(ansi yellow_bold)Applying `dot-github` Configuration...(ansi reset)\n"

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Configuration"
            metadata: { name: "devops-toolkit-dot-github" }
            spec: { package: "xpkg.upbound.io/devops-toolkit/dot-github:v0.0.57" }
        } | to yaml | kubectl apply --filename -

    }

    if $db or $github {

        {
            apiVersion: "rbac.authorization.k8s.io/v1"
            kind: "ClusterRole"
            metadata: {
                name: "crossplane-all"
                labels: {
                    "rbac.crossplane.io/aggregate-to-crossplane": "true"
                }
            }
            rules: [{
                apiGroups: ["*"]
                resources: ["*"]
                verbs: ["*"]
            }]
        } | to yaml | kubectl apply --filename -
    

        {
            apiVersion: "v1"
            kind: "ServiceAccount"
            metadata: {
                name: "crossplane-provider-helm"
                namespace: "crossplane-system"
            }
        } | to yaml | kubectl apply --filename -
        
        {
            apiVersion: "rbac.authorization.k8s.io/v1"
            kind: "ClusterRoleBinding"
            metadata: {  name: crossplane-provider-helm }
            subjects: [{
                kind: "ServiceAccount"
                name: "crossplane-provider-helm"
                namespace: "crossplane-system"
            }]
            roleRef: {
                kind: "ClusterRole"
                name: "cluster-admin"
                apiGroup: "rbac.authorization.k8s.io"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1alpha1"
            kind: "ControllerConfig"
            metadata: { name: "crossplane-provider-helm" }
            spec: { serviceAccountName: "crossplane-provider-helm" }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "crossplane-provider-helm" }
            spec: {
                package: "xpkg.upbound.io/crossplane-contrib/provider-helm:v0.19.0"
                controllerConfigRef: { name: "crossplane-provider-helm" }
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "v1"
            kind: "ServiceAccount"
            metadata: {
                name: "crossplane-provider-kubernetes"
                namespace: "crossplane-system"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "rbac.authorization.k8s.io/v1"
            kind: "ClusterRoleBinding"
            metadata: { name: "crossplane-provider-kubernetes" }
            subjects: [{
                kind: "ServiceAccount"
                name: "crossplane-provider-kubernetes"
                namespace: "crossplane-system"
            }]
            roleRef: {
                kind: "ClusterRole"
                name: "cluster-admin"
                apiGroup: "rbac.authorization.k8s.io"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1alpha1"
            kind: "ControllerConfig"
            metadata: { name: "crossplane-provider-kubernetes" }
            spec: { serviceAccountName: "crossplane-provider-kubernetes" }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "crossplane-provider-kubernetes" }
            spec: {
                package: "xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.15.0"
                controllerConfigRef: { name: "crossplane-provider-kubernetes" }
            }
        } | to yaml | kubectl apply --filename -

        main wait crossplane

        {
            apiVersion: "kubernetes.crossplane.io/v1alpha1"
            kind: "ProviderConfig"
            metadata: { name: "default" }
            spec: { credentials: { source: "InjectedIdentity" } }
        } | to yaml | kubectl apply --filename -

    }

    if $db and $provider != "none" {

        if $provider == "google" {
            (
                apply providerconfig $provider
                    --google_project_id $provider_data.project_id
            )
        } else {
            apply providerconfig $provider
        }


    }

    if ($github_user | is-not-empty) and ($github_token | is-not-empty) {

        {
            apiVersion: v1,
            kind: Secret,
            metadata: {
                name: github,
                namespace: crossplane-system
            },
            type: Opaque,
            stringData: {
                credentials: $"{\"token\":\"($github_token)\",\"owner\":\"($github_user)\"}"
            }
        } | to yaml | kubectl apply --filename -

        if $app or $github {

            {
                apiVersion: "github.upbound.io/v1beta1",
                kind: ProviderConfig,
                metadata: {
                    name: default
                },
                spec: {
                    credentials: {
                        secretRef: {
                            key: credentials,
                            name: github,
                            namespace: crossplane-system,
                        },
                        source: Secret
                    }
                }
            } | to yaml | kubectl apply --filename -

        }

    }

}

# Deletes Crossplane resources and waits for managed resources to be cleaned up
#
# Examples:
# > main delete crossplane
# > main delete crossplane --kind AppClaim --name myapp --namespace default
def "main delete crossplane" [
    --kind: string,
    --name: string,
    --namespace: string
] {

    if ($kind | is-not-empty) and ($name | is-not-empty) and ($namespace | is-not-empty) { 
        kubectl --namespace $namespace delete $kind $name
    }

    print $"\nWaiting for (ansi yellow_bold)Crossplane managed resources(ansi reset) to be deleted...\n"
    
    mut command = { kubectl get managed --output name }
    if ($name | is-not-empty) {
        $command = {
            (
                kubectl get managed --output name
                    --selector $"crossplane.io/claim-name=($name)"
            )
        }
    }

    mut resources = (do $command)
    mut counter = ($resources | wc -l | into int)

    while $counter > 0 {
        print $"($resources)\nWaiting for remaining (ansi yellow_bold)($counter)(ansi reset) managed resources to be (ansi yellow_bold)removed(ansi reset)...\n"
        sleep 10sec
        $resources = (do $command)
        $counter = ($resources | wc -l | into int)
    }

}

def "main publish crossplane" [
    package: string
    --sources = ["compositions"]
    --version = ""
] {

    mut version = $version
    if $version == "" {
        $version = $env.VERSION
    }

    package generate --sources $sources

    crossplane xpkg login --token $env.UP_TOKEN

    (
        crossplane xpkg build --package-root package
            --package-file $"($package).xpkg"
    )

    (
        crossplane xpkg push --package-files $"($package).xpkg"
            $"xpkg.upbound.io/($env.UP_ACCOUNT)/dot-($package):($version)"
    )

    rm --force $"package/($package).xpkg"

    open config.yaml
        | upsert spec.package $"xpkg.upbound.io/devops-toolkit/dot-($package):($version)"
        | save config.yaml --force

}

def "package generate" [
    --sources = ["compositions"]
] {

    for source in $sources {
        kcl run $"kcl/($source).k" |
            save $"package/($source).yaml" --force
    }

}

def "apply providerconfig" [
    provider: string,
    --google_project_id: string,
] {

    if $provider == "google" {

        {
            apiVersion: "gcp.upbound.io/v1beta1"
            kind: "ProviderConfig"
            metadata: { name: "default" }
            spec: {
                projectID: $google_project_id
                credentials: {
                    source: "Secret"
                    secretRef: {
                        namespace: "crossplane-system"
                        name: "gcp-creds"
                        key: "creds"
                    }
                }
            }
        } | to yaml | kubectl apply --filename -

    } else if $provider == "aws" {

        {
            apiVersion: "aws.upbound.io/v1beta1"
            kind: "ProviderConfig"
            metadata: { name: default }
            spec: {
                credentials: {
                    source: Secret
                    secretRef: {
                        namespace: crossplane-system
                        name: aws-creds
                        key: creds
                    }
                }
            }
        } | to yaml | kubectl apply --filename -
    
    } else if $provider == "azure" {

        {
            apiVersion: "azure.upbound.io/v1beta1"
            kind: "ProviderConfig"
            metadata: { name: default }
            spec: {
                credentials: {
                    source: "Secret"
                    secretRef: {
                        namespace: "crossplane-system"
                        name: "azure-creds"
                        key: "creds"
                    }
                }
            }
        } | to yaml | kubectl apply --filename -

    } else if $provider == "upcloud" {

        {
            apiVersion: "provider.upcloud.com/v1beta1"
            kind: "ProviderConfig"
            metadata: { name: default }
            spec: {
                credentials: {
                    source: "Secret"
                    secretRef: {
                        namespace: "crossplane-system"
                        name: "upcloud-creds"
                        key: "creds"
                    }
                }
            }
        } | to yaml | kubectl apply --filename -

    }

}

# Waits for all Crossplane providers to be deployed and healthy
def "main wait crossplane" [] {

    print $"\n(ansi yellow_bold)Waiting for Crossplane providers to be deployed...(ansi reset)\n"

    sleep 60sec

    (
        kubectl wait
            --for=condition=healthy provider.pkg.crossplane.io
            --all --timeout 30m
    )

}

def "setup google" [] {

    mut project_id = ""

    print $"\nInstalling (ansi yellow_bold)Crossplane Google Cloud Provider(ansi reset)...\n"

    if PROJECT_ID in $env {
        $project_id = $env.PROJECT_ID
    } else {

        gcloud auth login

        $project_id = $"dot-(date now | format date "%Y%m%d%H%M%S")"
        $env.PROJECT_ID = $project_id
        $"export PROJECT_ID=($project_id)\n" | save --append .env

        gcloud projects create $project_id

        start $"https://console.cloud.google.com/billing/enable?project=($project_id)"

        print $"
Select the (ansi yellow_bold)Billing account(ansi reset) and press the (ansi yellow_bold)SET ACCOUNT(ansi reset) button.
Press any key to continue.
"
        input

    }

    let sa_name = "devops-toolkit"

    let sa = $"($sa_name)@($project_id).iam.gserviceaccount.com"

    let project = $project_id

    do --ignore-errors {(
        gcloud iam service-accounts create $sa_name
            --project $project
    )}

    sleep 5sec

    (
        gcloud projects add-iam-policy-binding
            --role roles/admin $project_id
            --member $"serviceAccount:($sa)"
    )

    (
        gcloud iam service-accounts keys
            create gcp-creds.json --project $project_id
            --iam-account $sa
    )

    (
        kubectl --namespace crossplane-system
            create secret generic gcp-creds
            --from-file creds=./gcp-creds.json
    )

    { project_id: $project_id }

}

def "setup aws" [] {

    print $"\nInstalling (ansi yellow_bold)Crossplane AWS Provider(ansi reset)...\n"

    if AWS_ACCESS_KEY_ID not-in $env {
        $env.AWS_ACCESS_KEY_ID = input $"(ansi yellow_bold)Enter AWS Access Key ID: (ansi reset)"
    }
    $"export AWS_ACCESS_KEY_ID=($env.AWS_ACCESS_KEY_ID)\n"
        | save --append .env

    if AWS_SECRET_ACCESS_KEY not-in $env {
        $env.AWS_SECRET_ACCESS_KEY = input $"(ansi yellow_bold)Enter AWS Secret Access Key: (ansi reset)"
    }
    $"export AWS_SECRET_ACCESS_KEY=($env.AWS_SECRET_ACCESS_KEY)\n"
        | save --append .env

    $"[default]
aws_access_key_id = ($env.AWS_ACCESS_KEY_ID)
aws_secret_access_key = ($env.AWS_SECRET_ACCESS_KEY)
" | save aws-creds.conf --force

    (
        kubectl --namespace crossplane-system
            create secret generic aws-creds
            --from-file creds=./aws-creds.conf
            --from-literal $"accessKeyID=($env.AWS_ACCESS_KEY_ID)"
            --from-literal $"secretAccessKey=($env.AWS_SECRET_ACCESS_KEY)"
    )

}

def "setup azure" [
    --skip_login = false
] {

    print $"\nInstalling (ansi yellow_bold)Crossplane Azure Provider(ansi reset)...\n"

    mut azure_tenant = ""
    if AZURE_TENANT not-in $env {
        $azure_tenant = input $"(ansi yellow_bold)Enter Azure Tenant: (ansi reset)"
    } else {
        $azure_tenant = $env.AZURE_TENANT
    }
    $"export AZURE_TENANT=($azure_tenant)\n" | save --append .env

    if $skip_login == false { az login --tenant $azure_tenant }

    let subscription_id = (az account show --query id -o tsv)

    (
        az ad sp create-for-rbac --sdk-auth --role Owner
            --scopes $"/subscriptions/($subscription_id)"
            | save azure-creds.json --force
    )

    (
        kubectl --namespace crossplane-system
            create secret generic azure-creds
            --from-file creds=./azure-creds.json
    )

}

def "setup upcloud" [] {

    print $"\nInstalling (ansi yellow_bold)Crossplane UpCloud Provider(ansi reset)...\n"

    if UPCLOUD_USERNAME not-in $env {
        $env.UPCLOUD_USERNAME = input $"(ansi yellow_bold)UpCloud Username: (ansi reset)"
    }
    $"export UPCLOUD_USERNAME=($env.UPCLOUD_USERNAME)\n"
        | save --append .env

    if UPCLOUD_PASSWORD not-in $env {
        $env.UPCLOUD_PASSWORD = input $"(ansi yellow_bold)UpCloud Password: (ansi reset)"
    }
    $"export UPCLOUD_PASSWORD=($env.UPCLOUD_PASSWORD)\n"
        | save --append .env

    {
        apiVersion: "v1"
        kind: "Secret"
        metadata: {
            name: "upcloud-creds"
        }
        type: "Opaque"
        stringData: {
            creds: $"{\"username\": \"($env.UPCLOUD_USERNAME)\", \"password\": \"($env.UPCLOUD_PASSWORD)\"}"
        }
    } | to yaml | kubectl --namespace crossplane-system apply --filename -

}