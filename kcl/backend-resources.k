oxr = option("params").oxr
ocds = option("params").ocds
_name = oxr.metadata.name
_namespace = oxr.metadata.namespace
_spec = oxr.spec
_providerConfigName = _spec.providerConfigName
_targetNamespace = _spec.targetNamespace or _namespace

_object = lambda manifest: any, suffix: str -> any {
    {
        apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
        kind = "Object"
        metadata = {
            name = "{}-{}".format(_name, suffix)
            namespace = _targetNamespace
            annotations = {
                "krm.kcl.dev/ready" = "True"
                "krm.kcl.dev/composition-resource-name" = "{}-{}".format(_name, suffix)
            }
        }
        spec = {
            forProvider.manifest = manifest
            providerConfigRef = {
                name = _providerConfigName
                kind = "ClusterProviderConfig"
            }
        }
    }
}

_items = [
    _object({
        apiVersion = "apps/v1"
        kind = "Deployment"
        metadata = {
            name = _name
            namespace = _targetNamespace
            labels = {
                "app.kubernetes.io/name" = _name
            }
        }
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
                        if _spec.frontend?.backendUrl:
                            env = [
                                {
                                    name = "BACKEND_URL"
                                    value = _spec.frontend.backendUrl
                                }
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
    }, "deployment"),
    _object({
        apiVersion = "v1"
        kind = "Service"
        metadata = {
            name = _name
            namespace = _targetNamespace
            labels = {
                "app.kubernetes.io/name" = _name
            }
        }
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
    }, "service"),
    {
        **oxr
        status.host = _spec.host
    }
]

if _spec.routing == "gateway-api":
    _items += [_object({
        apiVersion = "gateway.networking.k8s.io/v1"
        kind = "HTTPRoute"
        metadata = {
            name = _name
            namespace = _targetNamespace
            labels = {
                "app.kubernetes.io/name" = _name
            }
        }
        spec = {
            parentRefs = [{
                name = "eg"
                namespace = "envoy-gateway-system"
            }]
            hostnames = [_spec.host]
            rules = [{
                matches = [{
                    path = {
                        type = "PathPrefix"
                        value = "/"
                    }
                }]
                if _spec.minReplicas == 0 and _spec.scaling?.enabled and _spec.scaling?.prometheusAddress:
                    backendRefs = [{
                        name = "keda-add-ons-http-interceptor-proxy"
                        namespace = "keda"
                        port = 8080
                    }]
                else:
                    backendRefs = [{
                        name = _name
                        port = _spec.port
                    }]
            }]
        }
    }, "httproute")]
else:
    _items += [_object({
        apiVersion = "networking.k8s.io/v1"
        kind = "Ingress"
        metadata = {
            name = _name
            namespace = _targetNamespace
            labels = {
                "app.kubernetes.io/name" = _name
            }
            annotations = {
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
    }, "ingress")]

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
    ] + ([
        {
            type = "external-push"
            metadata = {
                scalerAddress = "keda-add-ons-http-external-scaler.keda:9090"
                httpScaledObject = _name
            }
        }
    ] if _spec.minReplicas == 0 and _spec.routing == "gateway-api" else []) if _prom else [
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
    _items += [_object({
        apiVersion = "keda.sh/v1alpha1"
        kind = "ScaledObject"
        metadata = {
            name = _name
            namespace = _targetNamespace
            labels = {
                "app.kubernetes.io/name" = _name
            }
        }
        spec = {
            scaleTargetRef = {
                name = _name
            }
            minReplicaCount = _spec.minReplicas
            maxReplicaCount = _spec.maxReplicas
            triggers = _triggers
        }
    }, "scaled-object")]

if _spec.scaling?.enabled and _spec.minReplicas == 0 and _spec.scaling?.prometheusAddress and _spec.routing == "gateway-api":
    _items += [_object({
        apiVersion = "http.keda.sh/v1alpha1"
        kind = "HTTPScaledObject"
        metadata = {
            name = _name
            namespace = _targetNamespace
            annotations = {
                "httpscaledobject.keda.sh/skip-scaledobject-creation" = "true"
            }
            labels = {
                "app.kubernetes.io/name" = _name
            }
        }
        spec = {
            hosts = [_spec.host]
            scaleTargetRef = {
                name = _name
                service = _name
                port = _spec.port
            }
        }
    }, "http-scaled-object")]

if _spec.db?.storeName and _spec.db?.secret:
    _items += [_object({
        apiVersion = "external-secrets.io/v1"
        kind = "ExternalSecret"
        metadata = {
            name = _name
            namespace = _targetNamespace
            labels = {
                "app.kubernetes.io/name" = _name
            }
        }
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
    }, "external-secret")]

items = _items
