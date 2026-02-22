#!/usr/bin/env nu

# Installs Gateway API CRDs
#
# Examples:
# > main apply gateway_api
def "main apply gateway_api" [] {

    print $"Installing (ansi yellow_bold)Gateway API CRDs(ansi reset)..."

    (
        kubectl apply
            --filename https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
    )

}
