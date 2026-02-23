#!/usr/bin/env nu

# Installs KEDA HTTP Add-on for cold-start request handling during scale-to-zero
#
# Examples:
# > main apply keda_http_addon
def "main apply keda_http_addon" [] {

    print $"Installing (ansi yellow_bold)KEDA HTTP Add-on(ansi reset)..."

    (
        helm upgrade --install keda-add-ons-http keda-add-ons-http
            --repo https://kedacore.github.io/charts
            --namespace keda --create-namespace --wait
    )

    # Allow HTTPRoutes from any namespace to reference the interceptor Service in the keda namespace
    (kubectl apply --filename - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: keda-interceptor
  namespace: keda
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
  to:
    - group: ""
      kind: Service
EOF
    )

}
