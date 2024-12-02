import .common
import file

common.Composition {
    metadata = common.Metadata {
        name = "app-backend"
        labels = common.Labels {
            type = "backend"
            location = "local"
        }
    }
    spec = common.Spec {
        _kclResources = file.read("kcl/backend-resources.k")
        _kclCiResources = file.read("kcl/ci-resources.k")
    }
}

