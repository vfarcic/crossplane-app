import .common
import k8s.api.apps.v1 as k8sapps

schema Deployment:
  _dbEnabled: bool = False
  _dbSecretName: str = "spec.id"
  _providerConfigName: str = "spec.id"
  name = "deployment"
  base = common.KubernetesObjectBase{
    spec = common.KubernetesObjectSpec{
      forProvider = common.KubernetesObjectForProvider{
        manifest = k8sapps.Deployment{
          spec = {
            selector = {}
            template = {
              spec = {
                containers = [{
                  name = "backend"
                  ports = [{ containerPort = 80 }]
                  livenessProbe = { httpGet = { path = "/", port = 80 } }
                  readinessProbe = { httpGet = { path = "/", port = 80 } }
                  resources = {
                    limits = { cpu = "250m", memory = "256Mi" }
                    requests = { cpu = "125m", memory = "128Mi" }
                  }
                  if _dbEnabled:
                    env = [
                      { name = "DB_ENDPOINT", valueFrom.secretKeyRef.key = "endpoint" }
                      { name = "DB_PASSWORD", valueFrom.secretKeyRef.key = "password" }
                      { name = "DB_PORT", valueFrom.secretKeyRef = { key = "port",  optional = True } }
                      { name = "DB_USERNAME",  valueFrom.secretKeyRef.key = "username" }
                      { name = "DB_NAME" }
                    ]
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
    }
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.metadata.name" }
    { fromFieldPath = "spec.parameters.namespace", toFieldPath = "spec.forProvider.manifest.metadata.namespace" }
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.metadata.labels.app" }
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.spec.selector.matchLabels.app" }
    { fromFieldPath = "spec.id", toFieldPath = "spec.forProvider.manifest.spec.template.metadata.labels.app" }
    { fromFieldPath = "spec.parameters.image", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].image" }
    { fromFieldPath = "spec.parameters.port", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].ports[0].containerPort" }
    { fromFieldPath = "spec.parameters.port", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].livenessProbe.httpGet.port" }
    { fromFieldPath = "spec.parameters.port", toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].readinessProbe.httpGet.port" }
    if _dbEnabled:
      { fromFieldPath = _dbSecretName, toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].env[0].valueFrom.secretKeyRef.name" }
      { fromFieldPath = _dbSecretName, toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].env[1].valueFrom.secretKeyRef.name" }
      { fromFieldPath = _dbSecretName, toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].env[2].valueFrom.secretKeyRef.name" }
      { fromFieldPath = _dbSecretName, toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].env[3].valueFrom.secretKeyRef.name" }
      { fromFieldPath = _dbSecretName, toFieldPath = "spec.forProvider.manifest.spec.template.spec.containers[0].env[4].value" }
    { fromFieldPath = _providerConfigName, toFieldPath = "spec.providerConfigRef.name" }
  ]
