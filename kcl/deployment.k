import .common

schema Deployment:
  name = "deployment"
  base = common.KubernetesObjectBase{
    spec = common.KubernetesObjectSpec{
      forProvider = common.KubernetesObjectForProvider{
        manifest = {
          apiVersion = "apps/v1"
          kind = "Deployment"
          spec = {
            template = {
              spec = {
                containers = [{
                  name = "backend"
                  ports = [{ containerPort = 80 }]
                  livenessProbe = common.Probe{}
                  readinessProbe = common.Probe{}
                  resources = {
                    limits = { cpu = "250m", memory = "256Mi" }
                    requests = { cpu = "125m", memory = "128Mi" }
                  }
                  env = [{
                    name = "DB_ENDPOINT"
                    valueFrom.secretKeyRef.key = "endpoint"
                  }, {
                    name = "DB_PASSWORD"
                    valueFrom.secretKeyRef.key = "password"
                  }, {
                    name = "DB_PORT"
                    valueFrom.secretKeyRef = { key = "port",  optional = True }
                  }, {
                    name = "DB_USERNAME"
                    valueFrom.secretKeyRef.key = "username"
                  }, {
                    name = "DB_NAME"
                  }]
                }]
              }
            }
          }
        }
      }
    }
  }
  patches = [
    {
      fromFieldPath = "spec.id"
      toFieldPath = "metadata.name"
      transforms = [{ type = "string", string = { fmt = "%s-deployment" } }]
    },
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.metadata.name" },
    { fromFieldPath = "spec.parameters.namespace", toFieldPath = "spec.forProvider.manifest.metadata.namespace" },
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.metadata.labels.app" },
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.spec.selector.matchLabels.app" },
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.spec.template.metadata.labels.app" },
    { fromFieldPath = "spec.parameters.image", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].image" },
    { fromFieldPath = "spec.parameters.port", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].ports[0].containerPort" },
    { fromFieldPath = "spec.parameters.port", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].livenessProbe.httpGet.port" },
    { fromFieldPath = "spec.parameters.port", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].readinessProbe.httpGet.port" },
    { fromFieldPath = "spec.parameters.dbSecret.name", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].env[0].valueFrom.secretKeyRef.name" },
    { fromFieldPath = "spec.parameters.dbSecret.name", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].env[1].valueFrom.secretKeyRef.name" },
    { fromFieldPath = "spec.parameters.dbSecret.name", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].env[2].valueFrom.secretKeyRef.name" },
    { fromFieldPath = "spec.parameters.dbSecret.name", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].env[3].valueFrom.secretKeyRef.name" },
    { fromFieldPath = "spec.parameters.dbSecret.name", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].env[4].value" },
    { fromFieldPath = "spec.parameters.kubernetesProviderConfigName", toFieldPath = "spec.providerConfigRef.name" }
  ]
