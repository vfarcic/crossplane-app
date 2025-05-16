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
        apiVersion = "devopstoolkit.live/v1beta1"
        kind = "App"
    }
    mode = "Pipeline"
    pipeline = [
        {
            step = "kcl"
            functionRef.name = "crossplane-contrib-function-kcl"
            input = {
                apiVersion = "krm.kcl.dev/v1alpha1"
                kind = "KCLRun"
                metadata.name = "kubernetes"
                spec = {
                    target = "Default"
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

ManifestSpec = "spec.forProvider.manifest.spec"
