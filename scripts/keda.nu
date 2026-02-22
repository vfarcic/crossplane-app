#!/usr/bin/env nu

# Installs KEDA
#
# Examples:
# > main apply keda
def "main apply keda" [] {

    print $"Installing (ansi yellow_bold)KEDA(ansi reset)..."

    (
        helm upgrade --install keda keda
            --repo https://kedacore.github.io/charts
            --namespace keda --create-namespace --wait
    )

}
