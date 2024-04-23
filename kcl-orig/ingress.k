import .common
import k8s.api.networking.v1 as k8snetworking

schema Ingress(common.KubernetesObject):
    _providerConfigName: str = "spec.id"
    name = "ingress"
    base = common.KubernetesObjectBase {
        spec.forProvider.manifest = k8snetworking.Ingress{
            metadata.annotations = {"ingress.kubernetes.io/ssl-redirect" = "false" }
            spec.rules = [{
                http = {
                    paths = [{
                        path = "/"
                        pathType = "ImplementationSpecific"
                        backend.service.name = "acme"
                    }]
                }
            }]
        }
    }
    patches = common.Patches("ingress") + [
        {
            fromFieldPath = "spec.parameters.host",
            toFieldPath = "{}.rules[0].host".format(common.ManifestSpec) 
        }, {
            fromFieldPath = "spec.id",
            toFieldPath = "{}.rules[0].http.paths[0].backend.service.name".format(common.ManifestSpec)
        }, {
            fromFieldPath = "spec.parameters.port",
            toFieldPath = "{}.rules[0].http.paths[0].backend.service.port.number".format(common.ManifestSpec)
        }, {
            fromFieldPath = _providerConfigName,
            toFieldPath = "spec.providerConfigRef.name"
        }, {
            type = "ToCompositeFieldPath",
            fromFieldPath = "{}.rules[0].host".format(common.ManifestSpec),
            toFieldPath: "status.host"
        },
    ]
