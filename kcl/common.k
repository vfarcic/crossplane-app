schema Composition:
    apiVersion = "apiextensions.crossplane.io/v1"
    kind = "Composition"
    metadata: Metadata
    spec: Spec

schema Metadata:
    name: str
    labels: Labels

schema Spec:
    _kclResources: str
    compositeTypeRef = {
        apiVersion = "devopstoolkitseries.com/v1alpha1"
        kind = "App"
    }
    patchSets = [{
        name = "metadata"
        patches = [{fromFieldPath = "metadata.labels"}]
    }]
    mode = "Pipeline"
    pipeline = [
        {
            step = "kcl"
            functionRef.name = "kcl-function"
            input = {
                apiVersion = "krm.kcl.dev/v1alpha1"
                kind = "KCLRun"
                metadata.name = "kubernetes"
                spec = {
                    target = "Resources"
                    source = _kclResources
                }
            }
        }, {
            step = "automatically-detect-ready-composed-resources"
            functionRef.name = "crossplane-contrib-function-auto-ready"
        }
    ]

schema Labels:
    type: str
    location: str

schema KubernetesObject:
    name: str
    base = {
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
        kind = "Object"
        spec: KubernetesObjectSpec
    }
    patches: []

schema KubernetesObjectBase:
    apiVersion = "kubernetes.crossplane.io/v1alpha1"
    kind = "Object"
    spec: KubernetesObjectSpec

schema KubernetesObjectSpec:
    forProvider: KubernetesObjectForProvider

schema KubernetesObjectForProvider:
    manifest: any

Patches = lambda name: str -> [] {
    [
        {
            fromFieldPath = "spec.id"
            toFieldPath = "metadata.name"
            transforms = [{type = "string", string = {
                fmt = "%s-{}".format(name),
                type = "Format",
            }}]
        },
        {fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.metadata.name"},
        {fromFieldPath = "spec.parameters.namespace", toFieldPath = "spec.forProvider.manifest.metadata.namespace"},
        {fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.metadata.labels.app"},
    ]
}

ManifestSpec = "spec.forProvider.manifest.spec"
