import .common
import .deployment
import .service
import .ingress
import .kubernetesProviderConfig

common.Composition {
  metadata = common.Metadata {
    name = "app-backend"
    labels = common.Labels {
      type = "backend"
      location = "local"
    }
  }
  spec = common.Spec {
    resources = [
      kubernetesProviderConfig.KubernetesProviderConfig {}
      deployment.Deployment {}
      service.Service {}
      ingress.Ingress {}
    ]
  }
}
