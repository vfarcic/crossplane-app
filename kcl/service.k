import .common

schema Service:
  name = "service"
  base = common.KubernetesObjectBase {
    spec = common.KubernetesObjectSpec {
      forProvider = common.KubernetesObjectForProvider {
        manifest = {
          apiVersion = "v1"
          kind = "Service"
          spec = {
            type = "ClusterIP"
            ports = [{ protocol = "TCP", name = "http" }]
          }
        }
      }
    }
  }
  patches = [
    {
      fromFieldPath = "spec.id"
      toFieldPath = "metadata.name"
      transforms = [{ type = "string", string = { fmt = "%s-service" } }]
    },
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.metadata.name" },
    { fromFieldPath = "spec.parameters.namespace", toFieldPath = "spec.forProvider.manifest.metadata.namespace" },
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.metadata.labels.app" },
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.spec.selector.app" },
    { fromFieldPath = "spec.parameters.port", toFieldPath = "spec.forProvider.manifest.spec.ports[0].port" }, 
    { fromFieldPath = "spec.parameters.port", toFieldPath = "spec.forProvider.manifest.spec.ports[0].targetPort" }, 
    { fromFieldPath = "spec.parameters.kubernetesProviderConfigName", toFieldPath = "spec.providerConfigRef.name" }
  ]
