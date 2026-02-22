#!/usr/bin/env nu

# Installs KubeElasti
#
# Examples:
# > main apply kubeelasti
def "main apply kubeelasti" [] {

    print $"Installing (ansi yellow_bold)KubeElasti(ansi reset)..."

    (
        helm upgrade --install elasti
            oci://tfy.jfrog.io/tfy-helm/elasti
            --version 0.1.21
            --namespace elasti --create-namespace --wait
    )

}
