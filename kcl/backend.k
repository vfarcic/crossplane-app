import .common

common.Composition {
    metadata = common.Metadata {
        name = "app-backend"
        labels = common.Labels {
            type = "backend"
            location = "local"
        }
    }
    spec = common.Spec {
        _kclResources = """\
oxr = option("params").oxr
dxr = {
    **oxr
    status.host = oxr.spec.parameters.host
}
items = [
    {
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
        kind = "ProviderConfig"
        metadata.name = oxr.spec.id
        spec.credentials.source = "InjectedIdentity"
    } , {
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
        kind = "Object"
        metadata.name = "{}-deployment".format(oxr.spec.id)
        spec = {
            forProvider.manifest = {
                apiVersion = "apps/v1"
                kind = "Deployment"
                metadata = {
                    name = oxr.spec.id
                    namespace = oxr.spec.parameters.namespace
                    labels = {
                        "app.kubernetes.io/name" = oxr.spec.id
                    }
                }
                spec = {
                    selector.matchLabels = {
                        "app.kubernetes.io/name" = oxr.spec.id
                    }
                    template = {
                        metadata.labels = {
                            "app.kubernetes.io/name" = oxr.spec.id
                        }
                        spec = {
                            containers = [{
                                image = oxr.spec.parameters.image
                                name = "backend"
                                ports = [{containerPort = 80 }]
                                livenessProbe = {
                                    httpGet = {
                                        path = "/"
                                        port = oxr.spec.parameters.port
                                    }
                                }
                                readinessProbe = {
                                    httpGet = {
                                        path = "/"
                                        port = oxr.spec.parameters.port
                                    }
                                }
                                resources = {
                                    limits = {cpu = "250m", memory = "256Mi" }
                                    requests = {cpu = "125m", memory = "128Mi" }
                                }
                                ports = [
                                    {containerPort = oxr.spec.parameters.port }
                                ]
                                if oxr.spec.parameters?.db?.secret:
                                    env = [
                                        {
                                            name = "DB_ENDPOINT"
                                            valueFrom.secretKeyRef = {
                                                key = "endpoint"
                                                name = oxr.spec.parameters.db.secret
                                            }
                                        }, {
                                            name = "DB_PASSWORD"
                                            valueFrom.secretKeyRef = {
                                                key = "password"
                                                name = oxr.spec.parameters.db.secret
                                            }
                                        }, {
                                            name = "DB_PORT"
                                            valueFrom.secretKeyRef = {
                                                key = "port"
                                                name = oxr.spec.parameters.db.secret
                                                optional = True
                                            }
                                        }, {
                                            name = "DB_USERNAME"
                                            valueFrom.secretKeyRef = {
                                                key = "username"
                                                name = oxr.spec.parameters.db.secret
                                            }
                                        }, {
                                            name = "DB_NAME"
                                            value = oxr.spec.id
                                        },
                                    ]
                            }]
                        }
                    }
                }
            }
            providerConfigRef.name = oxr.spec.id
        }
    }, {
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
        kind = "Object"
        metadata.name = "{}-service".format(oxr.spec.id)
        spec = {
            forProvider.manifest = {
                apiVersion = "v1"
                kind = "Service"
                metadata = {
                    name = oxr.spec.id
                    namespace = oxr.spec.parameters.namespace
                    labels = {
                        "app.kubernetes.io/name" = oxr.spec.id
                    }
                }
                spec = {
                    type = "ClusterIP"
                    ports = [{
                        port = oxr.spec.parameters.port
                        targetPort = oxr.spec.parameters.port
                        protocol = "TCP"
                        name = "http"
                    }]
                    selector = {
                        "app.kubernetes.io/name" = oxr.spec.id
                    }
                }
            }
            providerConfigRef.name = oxr.spec.id
        }
    }, {
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
        kind = "Object"
        metadata.name = "{}-ingress".format(oxr.spec.id)
        spec = {
            forProvider.manifest = {
                apiVersion = "networking.k8s.io/v1"
                kind = "Ingress"
                metadata = {
                    name = oxr.spec.id
                    namespace = oxr.spec.parameters.namespace
                    labels = {
                        "app.kubernetes.io/name" = oxr.spec.id
                    }
                    annotations = {"ingress.kubernetes.io/ssl-redirect" = "false" }
                }
                spec.rules = [{
                    host = oxr.spec.parameters.host
                    http = {
                        paths = [{
                            path = "/"
                            pathType = "ImplementationSpecific"
                            backend.service = {
                                name = oxr.spec.id
                                port.number = oxr.spec.parameters.port
                            }
                        }]
                    }
                }]
            }
            providerConfigRef.name = oxr.spec.id
        }
    }
]
"""
    }
}

