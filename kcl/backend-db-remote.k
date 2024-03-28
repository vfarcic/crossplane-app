import .common
import .deployment
import .service
import .ingress

common.Composition {
  metadata = common.Metadata {
    name = "app-backend-db-remote"
    labels = common.Labels {
      type = "backend-db"
      location = "remote"
    }
  }
  spec = common.Spec {
    resources = [
      deployment.Deployment{
        _dbEnabled = True
        _dbSecretName = "spec.parameters.dbSecret.name"
        _providerConfigName = "spec.parameters.kubernetesProviderConfigName"
      }
      service.Service{
        _providerConfigName = "spec.parameters.kubernetesProviderConfigName"
      }
      ingress.Ingress{
        _providerConfigName = "spec.parameters.kubernetesProviderConfigName"
      }
    ]
  }
}
