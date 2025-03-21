oxr = option("params").oxr
_name = oxr.metadata.name
_spec = oxr.spec
dxr = {
    **oxr
    status.host = _spec.host
}

_metadata = lambda name: str, kind: str -> any {
    {
        name = name
        annotations = {
            "krm.kcl.dev/ready" = "True"
            "krm.kcl.dev/composition-resource-name" = "{}-{}".format(name, kind)
        }
        labels = {
            "app.kubernetes.io/name" = name
        }
    }
}

_items = [
    {
        apiVersion = "apps/v1"
        kind = "Deployment"
        metadata = _metadata(_name, "deployment")
        spec = {
            selector.matchLabels = {
                "app.kubernetes.io/name" = _name
            }
            template = {
                metadata.labels = {
                    "app.kubernetes.io/name" = _name
                }
                spec = {
                    containers = [{
                        image = _spec.image + ":" + _spec.tag
                        name = "main"
                        livenessProbe = {
                            httpGet = {
                                path = "/"
                                port = _spec.port
                            }
                        }
                        readinessProbe = {
                            httpGet = {
                                path = "/"
                                port = _spec.port
                            }
                        }
                        resources = {
                            limits = {cpu = "250m", memory = "256Mi" }
                            requests = {cpu = "125m", memory = "128Mi" }
                        }
                        ports = [
                            {containerPort = _spec.port }
                        ]
                        if _spec.db?.secret:
                            env = [
                                {
                                    name = "DB_ENDPOINT"
                                    valueFrom.secretKeyRef = {
                                        key = "endpoint"
                                        name = _spec.db.secret
                                    }
                                }, {
                                    name = "DB_PASSWORD"
                                    valueFrom.secretKeyRef = {
                                        key = "password"
                                        name = _spec.db.secret
                                    }
                                }, {
                                    name = "DB_PORT"
                                    valueFrom.secretKeyRef = {
                                        key = "port"
                                        name = _spec.db.secret
                                        optional = True
                                    }
                                }, {
                                    name = "DB_USERNAME"
                                    valueFrom.secretKeyRef = {
                                        key = "username"
                                        name = _spec.db.secret
                                    }
                                }, {
                                    name = "DB_NAME"
                                    value = _spec.db.name
                                },
                            ]
                    }]
                }
            }
        }
    }, {
        apiVersion = "v1"
        kind = "Service"
        metadata = _metadata(_name, "service")
        spec = {
            type = "ClusterIP"
            ports = [{
                port = _spec.port
                targetPort = _spec.port
                protocol = "TCP"
                name = "http"
            }]
            selector = {
                "app.kubernetes.io/name" = _name
            }
        }
    }, {
        apiVersion = "networking.k8s.io/v1"
        kind = "Ingress"
        metadata = {
            name = _name
            labels = {
                "app.kubernetes.io/name" = _name
            }
            annotations = {
                "krm.kcl.dev/ready" = "True"
                "krm.kcl.dev/composition-resource-name" = "{}-ingress".format(name)
                "ingress.kubernetes.io/ssl-redirect" = "false"
            }
        }
        spec = {
            if _spec.ingressClassName:
                ingressClassName = _spec.ingressClassName
            rules = [{
                host = _spec.host
                http = {
                    paths = [{
                        path = "/"
                        pathType = "ImplementationSpecific"
                        backend.service = {
                            name = _name
                            port.number = _spec.port
                        }
                    }]
                }
            }]
        }
    }
]

if _spec.scaling?.enabled:
    _items += [{
        apiVersion = "autoscaling/v2"
        kind = "HorizontalPodAutoscaler"
        metadata = _metadata(_name, "hpa")
        spec = {
            scaleTargetRef = {
                apiVersion = "apps/v1"
                kind = "Deployment"
                name = _name
            }
            minReplicas = _spec.scaling.min
            maxReplicas = _spec.scaling.max
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
    }]

if _spec.db?.storeName and _spec.db?.secret:
    _items += [{
        apiVersion = "external-secrets.io/v1beta1"
        kind = "ExternalSecret"
        metadata = _metadata(_name, "external-secret")
        spec = {
            dataFrom = [{
                extract = {
                    conversionStrategy = "Default"
                    decodingStrategy = "None"
                    key = _spec.db.secret
                    metadataPolicy = "None"
                }
            }]
            refreshInterval = "1h"
            secretStoreRef = {
                kind = "ClusterSecretStore"
                name = _spec.db.storeName
            }
            target = {
                creationPolicy = "Owner"
                deletionPolicy = "Retain"
                name = _spec.db.secret
            }
        }
    }]

items = _items

