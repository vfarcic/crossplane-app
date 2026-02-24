#!/usr/bin/env nu

source  scripts/common.nu
source  scripts/kubernetes.nu
source  scripts/ingress.nu
source  scripts/crossplane.nu
source  scripts/external-secrets.nu
source  scripts/gateway-api.nu
source  scripts/keda.nu
source  scripts/prometheus.nu
source  scripts/keda-http-addon.nu
source  scripts/provider-kubernetes.nu

def main [] {}

def "main setup" [] {

    rm --force .env

    main create kubernetes kind --name dot-app

    main apply ingress nginx --provider kind

    main apply gateway_api

    main apply keda

    apply_prometheus

    main apply keda_http_addon

    main apply crossplane

    print $"Applying (ansi yellow_bold)Crossplane Providers(ansi reset)..."

    let provider_files = [
        "function-auto-ready.yaml"
        "function-patch-and-transform.yaml"
        "github.yaml"
        "kcl.yaml"
        "provider-kubernetes.yaml"
    ]
    for file in $provider_files {
        kubectl apply --filename $"providers/($file)"
    }

    print $"Applying (ansi yellow_bold)Crossplane Composition(ansi reset)..."

    kubectl apply --filename package/definition.yaml

    sleep 1sec

    let package_files = [
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

    main destroy kubernetes kind --name dot-app

}

def "main setup-demo" [] {

    let provider = main get provider --providers [aws, azure, google]

    main create kubernetes kind --name dot-cp

    main apply crossplane --provider $provider --kubernetes-config true --app-config true

    main print source

}

def "main destroy-demo" [] {

    main destroy kubernetes kind --name dot-cp

}