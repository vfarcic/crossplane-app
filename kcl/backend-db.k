import .common
import .deployment
import .service
import .ingress
import .kubernetesProviderConfig

common.Composition {
  metadata = common.Metadata {
    name = "app-backend-db"
    labels = common.Labels {
      type = "backend-db"
      location = "local"
    }
  }
  spec = common.Spec {
    resources = [
      kubernetesProviderConfig.KubernetesProviderConfig {}
      deployment.Deployment {
        _dbEnabled = True
      }
      service.Service {}
      ingress.Ingress {}
    ]
  }
}
