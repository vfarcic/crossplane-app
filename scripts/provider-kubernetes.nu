#!/usr/bin/env nu

# Creates ClusterProviderConfig for provider-kubernetes with InjectedIdentity
#
# Examples:
# > main apply provider_kubernetes_config
def "main apply provider_kubernetes_config" [] {

    print $"Creating (ansi yellow_bold)provider-kubernetes ClusterProviderConfig(ansi reset)..."

    {
        apiVersion: "kubernetes.m.crossplane.io/v1alpha1"
        kind: "ClusterProviderConfig"
        metadata: {
            name: "local"
        }
        spec: {
            credentials: {
                source: "InjectedIdentity"
            }
        }
    } | to yaml | kubectl apply --filename -

}
