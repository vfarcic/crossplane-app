import .common

schema Ingress:
  name = "ingress"
  base = common.KubernetesObjectBase {
    spec = common.KubernetesObjectSpec {
      forProvider = common.KubernetesObjectForProvider {
        manifest = {
          apiVersion = "networking.k8s.io/v1"
          kind = "Ingress"
          metadata.annotations = { "ingress.kubernetes.io/ssl-redirect" = "false" }
          spec.rules = [{
            http = {
              paths = [{
                path = "/"
                pathType = "ImplementationSpecific"
              }]
            }
          }]
        }
      }
    }
  }
  patches = [
    {
      fromFieldPath = "spec.id"
      toFieldPath = "metadata.name"
      transforms = [{ type = "string", string = { fmt = "%s-ingress" } }]
    },
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.metadata.name" },
    { fromFieldPath = "spec.parameters.namespace", toFieldPath = "spec.forProvider.manifest.metadata.namespace" },
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.metadata.labels.app" },
    { fromFieldPath = "spec.parameters.host", toFieldPath = "spec.forProvider.manifest.spec.rules[0].host" },
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.spec.rules[0].http.paths[0].backend.service.name" },
    { fromFieldPath = "spec.parameters.port", toFieldPath = "spec.forProvider.manifest.spec.rules[0].http.paths[0].backend.service.port.number" },
    { fromFieldPath = "spec.parameters.kubernetesProviderConfigName", toFieldPath = "spec.providerConfigRef.name" }
    { type = "ToCompositeFieldPath", fromFieldPath = "spec.forProvider.manifest.spec.rules[0].host", toFieldPath: "status.host" }
  ]
