schema Composition:
    apiVersion = "apiextensions.crossplane.io/v1"
    kind = "Composition"
    metadata: Metadata
    spec: Spec

schema Metadata:
  name: str
  labels: Labels

schema Spec:
  compositeTypeRef = {
    apiVersion = "devopstoolkitseries.com/v1alpha1"
    kind = "App"
  }
  patchSets = [{
    name = "metadata"
    patches = [{
      fromFieldPath = "metadata.labels"
    }]
  }]
  resources: []

schema Labels:
  type: str
  location: str

schema Probe:
  httpGet = {
    path = "/"
    port = 80
  }

schema KubernetesObjectBase:
  apiVersion = "kubernetes.crossplane.io/v1alpha1"
  kind = "Object"
  spec: KubernetesObjectSpec

schema KubernetesObjectSpec:
  forProvider: KubernetesObjectForProvider

schema KubernetesObjectForProvider:
  manifest: any
