import .common
import k8s.api.core.v1 as k8core

schema Service(common.KubernetesObject):
    _providerConfigName: str = "spec.id"
    name = "service"
    base = common.KubernetesObjectBase {
        spec.forProvider.manifest = k8core.Service {
            spec: {
                type = "ClusterIP"
                ports = [{port = 8008, protocol = "TCP", name = "http"}]
            }
        }
    }
    patches = common.Patches("service") + [
        {fromFieldPath = "spec.id", toFieldPath = "{}.selector.app".format(common.ManifestSpec)}
        {fromFieldPath = "spec.parameters.port", toFieldPath = "{}.ports[0].port".format(common.ManifestSpec)}
        {fromFieldPath = "spec.parameters.port", toFieldPath = "{}.ports[0].targetPort".format(common.ManifestSpec)}
        {fromFieldPath = _providerConfigName, toFieldPath = "spec.providerConfigRef.name"}
    ]
