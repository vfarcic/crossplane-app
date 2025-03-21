#!/usr/bin/env nu

source  scripts/common.nu
source  scripts/kubernetes.nu
source  scripts/crossplane.nu
source  scripts/external-secrets.nu

def main [] {}

# Creates a local Kubernetes cluster
def "main setup" [
    --preview = false
] {

    rm --force .env

    main create kubernetes kind

    main apply crossplane --preview $preview

    print $"Applying (ansi yellow_bold)Crossplane Providers(ansi reset)..."

    let provider_files = [
        "cluster-role.yaml"
        "function-auto-ready.yaml"
        "function-patch-and-transform.yaml"
        "github.yaml"
        "kcl.yaml"
    ]  
    for file in $provider_files {
        kubectl apply --filename $"providers/($file)"
    }

    print $"Applying (ansi yellow_bold)Crossplane Composition(ansi reset)..."

    kubectl apply --filename package/definition.yaml

    sleep 1sec

    let package_files = [
        "frontend.yaml"
        "backend.yaml"
    ]
    for file in $package_files {
        kubectl apply --filename $"package/($file)"
    }

    main apply external_secrets

    print $"Waiting for (ansi yellow_bold)Crossplane providers(ansi reset) to be healthy..."

    (
        kubectl wait
            --for=condition=healthy provider.pkg.crossplane.io
            --all --timeout 300s
    )

    kubectl create namespace a-team

    main print source
    
}

def "main destroy" [] {

    main destroy kubernetes kind

}
