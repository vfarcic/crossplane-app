import .common
import .deployment
import .service
import .ingress

common.Composition {
    metadata = common.Metadata {
        name = "app-backend-db"
        labels = common.Labels {
            type = "backend-db"
            location = "local"
        }
    }
    spec = common.Spec {
        _resources = [
            deployment.Deployment {
                _dbEnabled = True
            }
            service.Service {}
            ingress.Ingress {}
        ]
        _kclResources = """\
oxr = option("params").oxr
items = [{
    apiVersion = "kubernetes.crossplane.io/v1alpha1"
    kind = "ProviderConfig"
    metadata.name = oxr.spec.id
    spec.credentials.source = "InjectedIdentity"
}]
"""
    }
}
