oxr = option("params").oxr
_id = oxr.spec.id
_params = oxr.spec.parameters
dxr = {
    **oxr
    status.host = _params.host
}

schema providerConfig:
    _apiVersion: str
    _suffix: str
    apiVersion = _apiVersion
    kind = "ProviderConfig"
    metadata = {
        name = _id + "-app"
        annotations = {
            "krm.kcl.dev/ready" = "True"
            "krm.kcl.dev/composition-resource-name" = _id + "-provider-config-" + _suffix
        }
    }
    spec = {
        credentials.source = "InjectedIdentity"
    }

_items = [
    providerConfig {
        _apiVersion = "kubernetes.crossplane.io/v1alpha1"
        _suffix = "kubernetes"
    } , {
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
        kind = "Object"
        metadata.name = "{}-deployment".format(_id)
        spec = {
            forProvider.manifest = {
                apiVersion = "apps/v1"
                kind = "Deployment"
                metadata = {
                    name = _id
                    namespace = _params.namespace
                    labels = {
                        "app.kubernetes.io/name" = _id
                    }
                }
                spec = {
                    selector.matchLabels = {
                        "app.kubernetes.io/name" = _id
                    }
                    template = {
                        metadata.labels = {
                            "app.kubernetes.io/name" = _id
                        }
                        spec = {
                            containers = [{
                                image = _params.image + ":" + _params.tag
                                name = "backend"
                                livenessProbe = {
                                    httpGet = {
                                        path = "/"
                                        port = _params.port
                                    }
                                }
                                readinessProbe = {
                                    httpGet = {
                                        path = "/"
                                        port = _params.port
                                    }
                                }
                                resources = {
                                    limits = {cpu = "250m", memory = "256Mi" }
                                    requests = {cpu = "125m", memory = "128Mi" }
                                }
                                ports = [
                                    {containerPort = _params.port }
                                ]
                                if _params.db?.secret:
                                    env = [
                                        {
                                            name = "DB_ENDPOINT"
                                            valueFrom.secretKeyRef = {
                                                key = "endpoint"
                                                name = _params.db.secret
                                            }
                                        }, {
                                            name = "DB_PASSWORD"
                                            valueFrom.secretKeyRef = {
                                                key = "password"
                                                name = _params.db.secret
                                            }
                                        }, {
                                            name = "DB_PORT"
                                            valueFrom.secretKeyRef = {
                                                key = "port"
                                                name = _params.db.secret
                                                optional = True
                                            }
                                        }, {
                                            name = "DB_USERNAME"
                                            valueFrom.secretKeyRef = {
                                                key = "username"
                                                name = _params.db.secret
                                            }
                                        }, {
                                            name = "DB_NAME"
                                            value = _id
                                        },
                                    ]
                            }]
                        }
                    }
                }
            }
            providerConfigRef.name = _id + "-app"
        }
    }, {
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
        kind = "Object"
        metadata.name = "{}-service".format(_id)
        spec = {
            forProvider.manifest = {
                apiVersion = "v1"
                kind = "Service"
                metadata = {
                    name = _id
                    namespace = _params.namespace
                    labels = {
                        "app.kubernetes.io/name" = _id
                    }
                }
                spec = {
                    type = "ClusterIP"
                    ports = [{
                        port = _params.port
                        targetPort = _params.port
                        protocol = "TCP"
                        name = "http"
                    }]
                    selector = {
                        "app.kubernetes.io/name" = _id
                    }
                }
            }
            providerConfigRef.name = _id + "-app"
        }
    }, {
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
        kind = "Object"
        metadata.name = "{}-ingress".format(_id)
        spec = {
            forProvider.manifest = {
                apiVersion = "networking.k8s.io/v1"
                kind = "Ingress"
                metadata = {
                    name = _id
                    namespace = _params.namespace
                    labels = {
                        "app.kubernetes.io/name" = _id
                    }
                    annotations = {"ingress.kubernetes.io/ssl-redirect" = "false" }
                }
                spec = {
                    if _params.ingressClassName:
                        ingressClassName = _params.ingressClassName
                    rules = [{
                        host = _params.host
                        http = {
                            paths = [{
                                path = "/"
                                pathType = "ImplementationSpecific"
                                backend.service = {
                                    name = _id
                                    port.number = _params.port
                                }
                            }]
                        }
                    }]
                }
            }
            providerConfigRef.name = _id + "-app"
        }
    }
]

if _params.scaling?.enabled:
    _items += [{
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
        kind = "Object"
        metadata.name = "{}-hpa".format(_id)
        spec = {
            forProvider.manifest = {
                apiVersion = "autoscaling/v2"
                kind = "HorizontalPodAutoscaler"
                metadata = {
                    name = _id
                    namespace = _params.namespace
                    labels = {
                        "app.kubernetes.io/name" = _id
                    }
                }
                spec = {
                    scaleTargetRef = {
                        apiVersion = "apps/v1"
                        kind = "Deployment"
                        name = _id
                    }
                    minReplicas = _params.scaling.min
                    maxReplicas = _params.scaling.max
                    metrics = [{
                        type = "Resource"
                        resource = {
                            name = "cpu"
                            target = {
                                type = "Utilization"
                                averageUtilization = 80
                            }
                        }
                    }, {
                        type = "Resource"
                        resource = {
                            name = "memory"
                            target = {
                                type = "Utilization"
                                averageUtilization = 80
                            }
                        }
                    }]
                }
            }
            providerConfigRef.name = _id + "-app"
        }
    }]

items = _items

