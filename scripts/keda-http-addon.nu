#!/usr/bin/env nu

# Installs KEDA HTTP Add-on for cold-start request handling during scale-to-zero
#
# Examples:
# > main apply keda_http_addon
def "main apply keda_http_addon" [] {

    print $"Installing (ansi yellow_bold)KEDA HTTP Add-on(ansi reset)..."

    (
        helm upgrade --install keda-add-ons-http keda-add-ons-http
            --repo https://kedacore.github.io/charts
            --namespace keda --create-namespace --wait
    )

}
