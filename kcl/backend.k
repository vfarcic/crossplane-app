import .common
import file

common.Composition {
    metadata = common.Metadata {
        name = "app-backend"
        labels = common.Labels {
            type = "backend"
        }
    }
    spec = common.Spec {
        _kclResources = file.read("kcl/backend-resources.k")
    }
}

