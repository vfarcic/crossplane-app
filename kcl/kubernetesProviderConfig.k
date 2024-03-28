schema KubernetesProviderConfig:
    name = "kubernetes"
    base = {
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
        kind = "ProviderConfig"
        spec.credentials.source = "InjectedIdentity"
    }
    patches = [
        {fromFieldPath = "spec.id", toFieldPath = "metadata.name"}
    ]
    readinessChecks = [{type = "None"}]
