import .common
import k8s.api.apps.v1 as k8sapps

schema Deployment(common.KubernetesObject):
    _dbEnabled: bool = False
    _dbSecretName: str = "spec.id"
    _providerConfigName: str = "spec.id"
    _container = "{}.template.spec.containers[0]".format(common.ManifestSpec)
    name = "deployment"
    base = common.KubernetesObjectBase{
        spec.forProvider.manifest = k8sapps.Deployment{
            spec = {
                selector = {}
                template = {
                    spec = {
                        containers = [{
                            name = "backend"
                            ports = [{containerPort = 80 }]
                            livenessProbe = {httpGet = {path = "/", port = 80 }}
                            readinessProbe = {httpGet = {path = "/", port = 80 }}
                            resources = {
                                limits = {cpu = "250m", memory = "256Mi" }
                                requests = {cpu = "125m", memory = "128Mi" }
                            }
                            if _dbEnabled:
                                env = [
                                    {name = "DB_ENDPOINT", valueFrom.secretKeyRef.key = "endpoint" },
                                    {name = "DB_PASSWORD", valueFrom.secretKeyRef.key = "password" },
                                    {name = "DB_PORT", valueFrom.secretKeyRef = {key = "port",  optional = True }},
                                    {name = "DB_USERNAME",  valueFrom.secretKeyRef.key = "username" },
                                    {name = "DB_NAME" },
                                ]
                        }]
                    }
                }
            }
        }
    }
    patches = common.Patches("deployment") + [
        {
            fromFieldPath = "spec.id",
            toFieldPath = "{}.selector.matchLabels.app".format(common.ManifestSpec)
        }, {
            fromFieldPath = "spec.id",
            toFieldPath = "{}.template.metadata.labels.app".format(common.ManifestSpec)
        }, {
            fromFieldPath = "spec.parameters.image",
            toFieldPath = "{}.image".format(_container)
        }, {
            fromFieldPath = "spec.parameters.port",
            toFieldPath = "{}.ports[0].containerPort".format(_container)
        }, {
            fromFieldPath = "spec.parameters.port",
            toFieldPath = "{}.livenessProbe.httpGet.port".format(_container)
        }, {
            fromFieldPath = "spec.parameters.port",
            toFieldPath = "{}.readinessProbe.httpGet.port".format(_container)
        },
        if _dbEnabled:
            {
                fromFieldPath = _dbSecretName,
                toFieldPath = "{}.env[0].valueFrom.secretKeyRef.name".format(_container)
            }, {
                fromFieldPath = _dbSecretName,
                toFieldPath = "{}.env[1].valueFrom.secretKeyRef.name".format(_container)
            }, {
                fromFieldPath = _dbSecretName,
                toFieldPath = "{}.env[2].valueFrom.secretKeyRef.name".format(_container)
            },
            {
                fromFieldPath = _dbSecretName,
                toFieldPath = "{}.env[3].valueFrom.secretKeyRef.name".format(_container)
            }, {
                fromFieldPath = _dbSecretName,
                toFieldPath = "{}.env[4].value".format(_container)
            },
        {
            fromFieldPath = _providerConfigName,
            toFieldPath = "spec.providerConfigRef.name"
        },
    ]
