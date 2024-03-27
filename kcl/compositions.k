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
      deployment.Deployment{}
      service.Service{}
      ingress.Ingress{}
    ]
  }
}
