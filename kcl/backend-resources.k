oxr = option("params").oxr
ocds = option("params").ocds
_name = oxr.metadata.name
_namespace = oxr.metadata.namespace
_spec = oxr.spec

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
            if not _spec.scaling?.enabled:
                replicas = _spec.minReplicas
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
                            failureThreshold = 10
                        }
                        readinessProbe = {
                            httpGet = {
                                path = "/"
                                port = _spec.port
                            }
                            failureThreshold = 10
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
        **oxr
        status.host = _spec.host
    }
]

if _spec.routing == "gateway-api":
    _items += [{
        apiVersion = "gateway.networking.k8s.io/v1"
        kind = "HTTPRoute"
        metadata = _metadata(_name, "httproute")
        spec = {
            parentRefs = [{
                name = "contour"
            }]
            hostnames = [_spec.host]
            rules = [{
                matches = [{
                    path = {
                        type = "PathPrefix"
                        value = "/"
                    }
                }]
                backendRefs = [{
                    name = _name
                    port = _spec.port
                }]
            }]
        }
    }]
else:
    _items += [{
        apiVersion = "networking.k8s.io/v1"
        kind = "Ingress"
        metadata = {
            name = _name
            labels = {
                "app.kubernetes.io/name" = _name
            }
            annotations = {
                "krm.kcl.dev/ready" = "True"
                "krm.kcl.dev/composition-resource-name" = "{}-ingress".format(_name)
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
    }]

if _spec.scaling?.enabled:
    if _spec.minReplicas == 0:
        assert _spec.scaling?.prometheusAddress, "minReplicas: 0 requires scaling.prometheusAddress (CPU/memory triggers need running pods)"
    _prom = _spec.scaling?.prometheusAddress
    _prom_query = "sum(rate(envoy_cluster_upstream_rq_total{{envoy_cluster_name=~\"httproute/{}/{}/.*\"}}[2m]))".format(_namespace, _name)
    _prom_threshold = str(_spec.scaling?.requestsPerReplica or 100)
    _triggers = [
        {
            type = "prometheus"
            metadata = {
                serverAddress = _prom
                query = _prom_query
                threshold = _prom_threshold
            }
        }
    ] if _prom else [
        {
            type = "cpu"
            metricType = "Utilization"
            metadata = {
                value = "80"
            }
        }
        {
            type = "memory"
            metricType = "Utilization"
            metadata = {
                value = "80"
            }
        }
    ]
    _items += [{
        apiVersion = "keda.sh/v1alpha1"
        kind = "ScaledObject"
        metadata = _metadata(_name, "scaled-object")
        spec = {
            scaleTargetRef = {
                name = _name
            }
            minReplicaCount = _spec.minReplicas
            maxReplicaCount = _spec.maxReplicas
            triggers = _triggers
        }
    }]

if _spec.db?.storeName and _spec.db?.secret:
    _items += [{
        apiVersion = "external-secrets.io/v1"
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

