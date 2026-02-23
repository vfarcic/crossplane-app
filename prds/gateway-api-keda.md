# PRD: Gateway API Routing and KEDA Autoscaling

**Status**: In Progress
**Priority**: High
**Created**: 2026-02-22

## Problem Statement

dot-application currently uses basic Kubernetes Ingress for routing and native HPA with CPU/memory metrics for scaling. This limits users in two ways:

1. **Routing**: Ingress is a legacy API with limited capabilities. Gateway API (`HTTPRoute`) offers header-based routing, traffic splitting, request mirroring, and better multi-tenancy — features that production applications increasingly need
2. **Scaling**: HPA with CPU/memory is a blunt instrument. Applications that serve traffic from queues, respond to webhook events, or have Prometheus-observable SLOs need event-driven scaling. KEDA provides this with 60+ scalers, scale-to-zero support, and Prometheus integration

## Context

dot-kubernetes will install Envoy Gateway and KEDA as system-level components (see [crossplane-kubernetes Gateway + KEDA PRD]). This PRD focuses on how dot-application **consumes** those components by generating the right resources in its composition.

This work also serves as a proving ground for the combined Gateway API + KEDA pattern. Lessons learned here — composition patterns, KCL abstractions, testing approaches, API design — will directly inform the more complex inference-specific implementation in crossplane-inference.

### Current State

- **Routing**: Composition generates `networking.k8s.io/v1 Ingress` with a single path rule
- **Scaling**: Composition generates `autoscaling/v2 HorizontalPodAutoscaler` with CPU (80%) and memory (80%) targets, optional via `spec.scaling.enabled`
- **Composition language**: KCL via `function-kcl`

## Proposed API Surface

### Routing

Extend the XRD to support Gateway API alongside existing Ingress:

```yaml
spec:
  routing: gateway-api  # or "ingress" (default, backward compatible)
  host: my-app.example.com
  port: 8080
```

When `routing: gateway-api`:
- Generate `HTTPRoute` instead of `Ingress`
- Route attaches to the default `Gateway` created by dot-kubernetes
- Support the same `host` and `port` fields — no new API surface needed for basic use

Future extensions (not in this PRD):
- Traffic splitting (`spec.routing.canary.weight: 10`)
- Header-based routing
- Request mirroring

### Object Wrapping (provider-kubernetes)

All composed resources are wrapped in `kubernetes.m.crossplane.io/v1alpha1 Object` CRs managed by provider-kubernetes. This is mandatory — there is no "raw" path.

```yaml
spec:
  providerConfigName: my-cluster  # required — ProviderConfig for provider-kubernetes
  targetNamespace: my-app-ns      # required — namespace where resources are created
```

**Why mandatory**: Gateway API's ReferenceGrant requires a per-app entry in the `keda` namespace for cross-namespace HTTPRoute→Service references (cold-start interceptor routing). Crossplane's `target: Default` overrides the namespace on namespace-scoped composed resources, making it impossible to create resources in a different namespace than the XR's. Object wrapping solves this — provider-kubernetes respects `forProvider.manifest.metadata.namespace` regardless of where the Object CR itself lives. By always using Object wrapping, cold-start handling works on every cluster (same-cluster or remote), and the composition has a single code path.

For same-cluster deployments, users create a ProviderConfig with `InClusterConfig` or `InjectedIdentity`. For remote clusters, the ProviderConfig points to the remote cluster's kubeconfig.

### Replicas and Scaling

Replica count and scaling configuration are separated: `minReplicas`/`maxReplicas` live at the top level of `spec`, while `scaling` controls *how* (or whether) autoscaling works.

```yaml
spec:
  minReplicas: 3      # static replica count when scaling disabled; min bound when enabled (default: 1, 0 for scale-to-zero)
  maxReplicas: 10     # only used when scaling is enabled (default: 10)
  scaling:
    enabled: true      # generates KEDA ScaledObject with CPU/memory triggers
```

Scale-to-zero with Prometheus trigger:
```yaml
spec:
  minReplicas: 0
  maxReplicas: 10
  scaling:
    enabled: true
    prometheusAddress: http://kube-prometheus-stack-prometheus.prometheus-system:9090
    requestsPerReplica: 100  # each replica handles ~100 req/s before scaling adds another (default: 100)
```

**Behavior**:
- `scaling.enabled: false` (default) → Deployment gets `spec.replicas: minReplicas`; `maxReplicas` is ignored
- `scaling.enabled: true` (no `prometheusAddress`) → KEDA ScaledObject with CPU and memory triggers using `minReplicas`/`maxReplicas`
- `scaling.enabled: true` + `scaling.prometheusAddress` set → KEDA ScaledObject with Prometheus trigger querying Envoy Gateway metrics; `scaling.requestsPerReplica` controls the trigger threshold (default: 100); enables `minReplicas: 0` for scale-to-zero
- `minReplicas: 0` requires `scaling.prometheusAddress` — CPU/memory triggers cannot support scale-to-zero since those metrics require running pods

### Scale-to-Zero: Metric Source and Cold Start — Resolved

**Metric source**: Use KEDA's Prometheus trigger pointing at Envoy Gateway's **upstream cluster metrics** (`envoy_cluster_upstream_rq_total`). The query `sum(rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/<namespace>/<name>/.*"}[2m]))` scopes to a specific application using Envoy's cluster naming convention (`httproute/<namespace>/<route-name>/rule/<index>`). Initially we tried `envoy_http_downstream_rq_total`, but discovered that downstream metrics are per-listener and match ALL workloads on the Gateway — not suitable for per-app scaling. The upstream cluster metric provides per-app granularity. Note: at zero replicas, this metric reads as 0, which is the desired behavior (KEDA keeps the workload scaled to zero until requests arrive and the metric rises). This uses the same `ScaledObject` resource as CPU/memory scaling — just a different trigger type — keeping the composition simple.

**KEDA HTTP Add-on for cold-start handling**: Initially rejected due to beta status and architectural complexity, but reconsidered after KubeElasti proved incompatible with Crossplane. The HTTP Add-on (v0.12.2, Feb 2026) uses an interceptor proxy that holds requests during scale-from-zero until pods are ready. Crucially, it is **Crossplane-compatible** — it never touches, copies, or sets ownerReferences on user Services (unlike KubeElasti). The operator creates only a `ScaledObject` owned by its `HTTPScaledObject` CRD. The interceptor reads EndpointSlices but never modifies them. Trade-offs: (1) still beta — KEDA project explicitly says not recommended for production; (2) adds a proxy in the request path (`Gateway → Interceptor → App`); (3) HTTPRoute backendRef must point to the interceptor Service instead of the app Service when `minReplicas: 0`; (4) uses `HTTPScaledObject` CRD. Despite these, it is the only viable cold-start solution that works with Crossplane's ownership model.

**Dual-trigger ScaledObject for cold-start scaling**: The `skip-scaledobject-creation` annotation on `HTTPScaledObject` prevents the HTTP Add-on from creating its own ScaledObject, but the Prometheus trigger alone cannot detect cold-start requests — the interceptor holds requests before they reach the app, so the Prometheus metric stays at 0 and KEDA never scales up. The solution is a single ScaledObject with **two triggers**: (1) Prometheus trigger for load-based scaling when pods are running, and (2) `external-push` trigger pointing at the HTTP Add-on's external scaler (`keda-add-ons-http-external-scaler.keda:9090`) which detects pending requests in the interceptor queue. KEDA evaluates all triggers and uses the maximum, so the external-push trigger handles scale-from-zero while Prometheus handles steady-state scaling. Verified end-to-end: HTTP 200 with `x-keda-http-cold-start: true` header, ~3s cold-start latency.

**Cold start and request handling**: When KEDA scales from zero, there is a window (~15-30s) where no pods are available. During manual testing, we confirmed that Envoy Gateway returns **503 immediately** when there are zero upstream endpoints — it short-circuits before retry logic is engaged, so BackendTrafficPolicy retry/timeout policies **do not help**. This is a fundamental Envoy behavior, not a configuration issue.

**KubeElasti** (CNCF Sandbox) was evaluated as a cold-start solution but is **not compatible with Crossplane**. Three upstream bugs were found during manual testing: (1) `sync.Once` in informer registration is not reset on failure, causing silent failures when the Deployment isn't ready at first reconcile; (2) the `triggers` field is required but undocumented; (3) `checkAndCreatePrivateService` uses `DeepCopy` on the public Service, which copies Crossplane's ownerReferences (`controller: true`), then fails when setting its own controller reference. Bug #3 is a fundamental incompatibility — any controller-managed Service will hit this.

### Discussion: Which scaling API approach? — **Resolved**

Start with KEDA ScaledObject as the only autoscaling mechanism (no HPA). The presence of `scaling.prometheusAddress` selects Prometheus trigger; omitting it defaults to CPU/memory triggers. No `scaling.type` enum needed — Prometheus is currently the only alternative trigger, so a single-value enum would be over-engineering.

### Discussion: Where do replica fields live? — **Resolved**

`minReplicas` and `maxReplicas` are top-level `spec` fields rather than nested under `scaling`. This avoids field duplication: `minReplicas` serves as both the static replica count (scaling off) and the scaling floor (scaling on). The `scaling` object is purely about *how* to scale, not *how many*.

## Implementation Approach

### KCL Changes

Modify `kcl/backend-resources.k` to:

1. **Object wrapping**: All resources wrapped in `kubernetes.m.crossplane.io/v1alpha1 Object` CRs via an `_object` lambda. Each Object CR includes `providerConfigRef` (from `spec.providerConfigName`) and sets the target namespace via `forProvider.manifest.metadata.namespace`. No raw `krm.kcl.dev` annotation path.

2. **Routing**: Add conditional resource generation based on `spec.routing`:
   - `routing: ingress` (or unset) → generate `Ingress` (current behavior)
   - `routing: gateway-api` → generate `HTTPRoute` referencing the default `Gateway`

3. **Scaling**: Replace HPA with KEDA ScaledObject:
   - Remove HPA generation entirely
   - When `scaling.enabled: true` → generate `keda.sh/v1alpha1 ScaledObject` with CPU and memory triggers
   - ScaledObject targets the Deployment by name
   - `minReplicas`/`maxReplicas` passed to ScaledObject

4. **Prometheus trigger**: Add Prometheus-based scaling for scale-to-zero:
   - When `scaling.prometheusAddress` is set → generate ScaledObject with Prometheus trigger instead of CPU/memory triggers
   - PromQL query: `sum(rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/<namespace>/<name>/.*"}[2m]))` — per-app upstream cluster metric using Envoy's naming convention
   - `prometheusAddress` specifies the Prometheus server URL
   - `requestsPerReplica` (default 100) used as Prometheus trigger `threshold` — KEDA calculates desired replicas as `metricValue / threshold`
   - Enables `minReplicas: 0` for scale-to-zero

5. **ReferenceGrant**: When `routing == "gateway-api"` AND `minReplicas == 0` AND `prometheusAddress` → generate per-app ReferenceGrant Object CR in `keda` namespace, allowing HTTPRoute from the app's namespace to reference the interceptor Service

### XRD Changes

Extend `package/definition.yaml` with:
- `spec.providerConfigName` (string, required) — ProviderConfig name for provider-kubernetes; used for both same-cluster and remote-cluster deployments
- `spec.targetNamespace` (string, required) — namespace where actual resources (Deployment, Service, etc.) are created
- `spec.routing` enum field (`ingress`, `gateway-api`)
- `spec.minReplicas` (integer, minimum 0, default 1) — replaces `spec.scaling.min`
- `spec.maxReplicas` (integer, default 10) — replaces `spec.scaling.max`
- `spec.scaling.prometheusAddress` (string) — Prometheus server URL; when set, selects Prometheus trigger instead of CPU/memory; required for `minReplicas: 0`
- `spec.scaling.requestsPerReplica` (integer, default 100) — requests per second each replica can handle; used as KEDA Prometheus trigger threshold; only applies when `prometheusAddress` is set
- Remove `spec.scaling.min` and `spec.scaling.max` (moved to top level)

### Backward Compatibility — Breaking Changes (Major Version Bump)

This PRD introduces breaking changes requiring a major version bump:

- **`providerConfigName` required**: All App XRs must specify a ProviderConfig for provider-kubernetes. Users need to install provider-kubernetes and create a ProviderConfig (e.g., `InjectedIdentity` for same-cluster)
- **`targetNamespace` required**: All App XRs must specify the target namespace for resource creation
- **All resources wrapped in Object CRs**: Composition no longer creates resources directly via `krm.kcl.dev` annotations — all resources are `kubernetes.m.crossplane.io/v1alpha1 Object` CRs managed by provider-kubernetes
- **provider-kubernetes is a hard dependency**: Added to `package/crossplane.yaml`
- HPA removed entirely — `scaling.enabled: true` now generates KEDA ScaledObject instead of HPA
- Default `routing` to `ingress`, `minReplicas: 1`, `maxReplicas: 10` — matches current scaling defaults

## Testing

### KinD Test Environment

This is designed to be fully testable in a local KinD cluster:

1. Install KEDA and Envoy Gateway via Helm in the test cluster setup
2. Install Prometheus (kube-prometheus-stack or similar) for Prometheus trigger tests
3. Install provider-kubernetes with `InjectedIdentity` ProviderConfig for same-cluster Object wrapping
4. Create a `Gateway` resource with HTTP listener
5. Deploy a test application via the App XR with `providerConfigName`, `targetNamespace`, and `routing: gateway-api`
6. Assert Object CRs are created wrapping the actual resources (Deployment, Service, HTTPRoute, etc.)
7. Assert actual resources exist in the target namespace
8. Deploy with `scaling.enabled: true`
9. Assert ScaledObject Object CR and actual ScaledObject with correct triggers
10. Deploy with `scaling.prometheusAddress` and `minReplicas: 0`
11. Assert ScaledObject with Prometheus trigger, HTTPScaledObject, and ReferenceGrant in `keda` namespace

No GPUs, no cloud resources, no inference stack — just standard Kubernetes resources.

### Test Cases

- **Routing: Ingress (default)** — existing behavior, no regression
- **Routing: Gateway API** — HTTPRoute generated, Ingress not generated
- **Replicas: static** — Deployment gets `spec.replicas` from `minReplicas` when scaling disabled
- **Scaling: KEDA CPU/memory** — ScaledObject with CPU and memory triggers, no `spec.replicas` on Deployment
- **Scaling: Prometheus trigger** — ScaledObject with Prometheus trigger, correct serverAddress and query
- **Scaling: scale-to-zero** — ScaledObject with `minReplicaCount: 0` and Prometheus trigger (CPU/memory triggers reject minReplicas: 0)
- **Combined** — Gateway API routing + KEDA scaling together

## Lessons for crossplane-inference

This PRD explicitly serves as a precursor to the inference-specific implementation. Key transferable patterns:

- **KCL patterns for conditional resource generation** (Ingress vs HTTPRoute, KEDA ScaledObject)
- **XRD design for routing and scaling options** — the inference XRD will mirror this API structure
- **Testing approach** — KEDA and Envoy Gateway in KinD without cloud dependencies
- **ScaledObject composition** — how to target operator-managed Deployments

What **won't** transfer:
- Inference Extension resources (InferencePool, InferenceModel) — unique to inference
- vLLM-specific KEDA metrics — different trigger configuration
- KV-cache-aware load balancing — inference-only concern

## Progress

### Routing (Gateway API)
- [x] XRD: `spec.routing` enum field (`ingress`, `gateway-api`) with default `ingress`
- [x] KCL: Conditional HTTPRoute generation when `routing: gateway-api`
- [x] KCL: Ingress generation preserved as default (backward compatible)
- [x] Tests: Chainsaw test for gateway-api routing with HTTPRoute assertion
- [x] Reconcile gateway parentRef name with crossplane-kubernetes — updated from `contour` to `eg` with `namespace: envoy-gateway-system`

### Replicas
- [x] XRD: Move replica fields to `spec.minReplicas` (min 0, default 1) and `spec.maxReplicas` (default 10); remove `spec.scaling.min`/`spec.scaling.max`
- [x] KCL: Set Deployment `spec.replicas` from `minReplicas` when scaling is disabled
- [x] KCL: Remove HPA generation entirely
- [x] Tests: Verify Deployment replicas set correctly when scaling is disabled

### Scaling (KEDA — CPU/memory)
- [x] KCL: KEDA ScaledObject generation with CPU/memory triggers using `minReplicas`/`maxReplicas`
- [x] Tests: KEDA installed in test setup (full operator via Helm)
- [x] Tests: KEDA CPU/memory scaling test
- [~] Tests: Scale-to-zero (minReplicas: 0) test — moved to Prometheus section; KEDA rejects minReplicas: 0 with CPU/memory triggers since those metrics require running pods
- [x] Tests: Combined Gateway API routing + KEDA scaling test

### Scaling (KEDA — Prometheus + Scale-to-Zero)
- [x] XRD: Add `spec.scaling.prometheusAddress` field (string; presence selects Prometheus trigger, required for `minReplicas: 0`)
- [x] KCL: ScaledObject generation with Prometheus trigger when `prometheusAddress` is set — query uses `envoy_cluster_upstream_rq_total` per-app upstream metric
- [x] KCL: Validate `minReplicas: 0` requires `scaling.prometheusAddress` (CPU/memory triggers cannot support scale-to-zero)
- [x] Tests: Install Prometheus (kube-prometheus-stack) in test cluster setup
- [x] Tests: Prometheus trigger scaling test — assert ScaledObject with correct trigger type, serverAddress, and query
- [x] Tests: Scale-to-zero test — assert ScaledObject with `minReplicaCount: 0` and Prometheus trigger
- [x] Manual verification: scale-to-zero and scale-from-zero confirmed working in KinD with Envoy Gateway + KEDA + Prometheus
- [x] Reconcile Prometheus service URL/namespace with crossplane-kubernetes — confirmed `http://kube-prometheus-stack-prometheus.prometheus-system:9090` is correct and stable
- [x] XRD: Add `spec.scaling.requestsPerReplica` field (integer, default 100)
- [x] KCL: Use `requestsPerReplica` as Prometheus trigger threshold (currently hardcoded to `"1"`)
- [x] Tests: Update Prometheus scaling tests to assert configurable threshold

### Cold-Start Request Handling (KubeElasti) — Abandoned
- [x] Investigate Envoy Gateway retry/timeout policies — confirmed NOT viable (Envoy 503s immediately with 0 endpoints)
- [x] Research KubeElasti (CNCF Sandbox) as cold-start solution
- [x] Install KubeElasti in test cluster setup
- [x] KCL: Generate `ElastiService` CRD alongside ScaledObject when `minReplicas: 0`
- [x] Manual verification: KubeElasti is **not compatible with Crossplane** — three upstream bugs found (sync.Once not reset, undocumented triggers field, DeepCopy copies ownerReferences breaking controller reference)
- [x] KCL: Removed ElastiService generation; cold-start 503s accepted as known limitation
- [~] Tests: Chainsaw test for ElastiService generation — removed (ElastiService no longer generated)
- [~] Feature request to crossplane-kubernetes to install KubeElasti — not needed (KubeElasti abandoned)

### Cold-Start Request Handling (KEDA HTTP Add-on)
- [x] Install KEDA HTTP Add-on in test cluster setup (Helm chart) — `scripts/keda-http-addon.nu` created, `dot.nu` updated (replaced KubeElasti), verified interceptor proxy and `httpscaledobjects.http.keda.sh` CRD running
- [x] KCL: Generate `HTTPScaledObject` CRD when `minReplicas: 0` and `prometheusAddress` is set — uses `skip-scaledobject-creation` annotation; ScaledObject includes both Prometheus trigger (for load-based scaling) and `external-push` trigger (for interceptor cold-start signaling); HTTPScaledObject configures the interceptor for request holding
- [x] KCL: Conditionally set HTTPRoute backendRef to interceptor Service (`keda-add-ons-http-interceptor-proxy`) when `minReplicas: 0`, app Service otherwise — routes to interceptor in `keda` namespace on port 8080; ReferenceGrant added to `scripts/keda-http-addon.nu` for cross-namespace access
- [x] Manual verification: deploy app with scale-to-zero, wait for KEDA to scale to zero, send request, confirm interceptor holds request until pods are ready (no 503) — confirmed working: HTTP 200 with `x-keda-http-cold-start: true` header, ~3s cold-start latency; required adding `external-push` trigger to ScaledObject (see decision log)
- [x] Tests: Chainsaw test for HTTPScaledObject generation when `minReplicas: 0` — asserts HTTPScaledObject with correct hosts, scaleTargetRef, and skip-scaledobject-creation annotation
- [x] Tests: Chainsaw test for HTTPRoute backendRef pointing to interceptor when `minReplicas: 0` — reuses existing gateway-api patch on top of scale-to-zero state; asserts backendRef points to `keda-add-ons-http-interceptor-proxy` in `keda` namespace
- [x] Feature request to crossplane-kubernetes to install KEDA HTTP Add-on on managed clusters — request written to `../crossplane-kubernetes/tmp/feature-request.md`
- [ ] End-to-end validation on a real cluster provisioned by crossplane-kubernetes — after crossplane-kubernetes processes the feature request and provisions a cluster with KEDA HTTP Add-on, deploy an App XR with scale-to-zero + gateway-api routing and verify cold-start handling works in a non-KinD environment; if issues found, either fix in crossplane-app or create a new feature request to crossplane-kubernetes

### KEDA HTTP Add-on: Routing Gate and ReferenceGrant
HTTPScaledObject, external-push trigger, and interceptor backendRef are currently generated whenever `minReplicas: 0` + `prometheusAddress`, regardless of routing type. These only function with `routing: gateway-api` (traffic must flow through the Gateway API HTTPRoute to the interceptor). With Ingress routing, the interceptor never receives traffic, making these resources useless.

**ReferenceGrant**: Gateway API requires a per-app ReferenceGrant in the `keda` namespace to allow cross-namespace HTTPRoute→Service references to the interceptor. The `namespace` field in `spec.from` is required (no wildcard support), so crossplane-kubernetes cannot create a universal grant. The per-app ReferenceGrant is created by the composition as an Object CR — since all resources are Object-wrapped, provider-kubernetes places it in the `keda` namespace correctly. For local KinD testing, the setup script (`scripts/keda-http-addon.nu`) creates a ReferenceGrant covering the test namespace.

- [x] KCL: Gate HTTPScaledObject, external-push trigger, and interceptor HTTPRoute backendRef on `routing == "gateway-api"`
- [x] KCL: Generate per-app ReferenceGrant in `keda` namespace when `routing == "gateway-api"` AND `minReplicas == 0` AND `prometheusAddress` — Object wrapping ensures correct namespace placement
- [x] Tests: Update consolidated `assert-scaling.yaml` to include ReferenceGrant assertion (scaling tests now use single combined patch+assert)
- [x] Tests: Run full `task test` to confirm all existing tests pass

### Object Wrapping (Mandatory)
**Implementation approach**: All composed resources are wrapped in `kubernetes.m.crossplane.io/v1alpha1 Object` CRs. There is no "raw" path — every resource goes through provider-kubernetes. A single `_object` lambda wraps any manifest in an Object CR with `providerConfigRef` and sets the target namespace via `forProvider.manifest.metadata.namespace`.

**Why mandatory**: Gateway API's ReferenceGrant requires a per-app entry in the `keda` namespace, and the `namespace` field in `spec.from` is required (no wildcard). Crossplane's `target: Default` overrides namespaces on namespace-scoped composed resources, making it impossible to create the ReferenceGrant in `keda` via the raw path. Object wrapping solves this universally — same-cluster or remote. A single code path is simpler to maintain and test than conditional `_raw`/`_wrapped` branching.

- [x] XRD: Add `spec.providerConfigName` (string, required) and `spec.targetNamespace` (string, optional — defaults to XR namespace via `_oxr.metadata.namespace`)
- [x] KCL: `_object` lambda — wraps manifest in `kubernetes.m.crossplane.io/v1alpha1 Object` with `providerConfigRef` (uses `kind: ClusterProviderConfig` for namespace-scoped `.m.` API); sets namespace from `_targetNamespace`
- [x] KCL: Refactor all resource creation through `_object` — Deployment, Service, Ingress/HTTPRoute, ScaledObject, HTTPScaledObject
- [x] KCL: Remove `krm.kcl.dev` annotation-based resource creation entirely
- [x] Setup: Install provider-kubernetes, grant its SA cluster-admin RBAC
- [x] Setup: Create `ClusterProviderConfig` with `InjectedIdentity` for same-cluster testing
- [x] Add provider-kubernetes to `package/crossplane.yaml` dependencies
- [x] Regenerate `package/backend.yaml` via KCL
- [x] Tests: All existing tests updated — App XRs specify `providerConfigName` + `targetNamespace`, assert Object CRs wrapping actual resources; scaling tests consolidated into single patch+assert cycle
- [x] Frontend composition removed — backend composition handles all app types (frontend uses `spec.frontend.backendUrl` for `BACKEND_URL` env var)
- [ ] Bump major version (breaking change: `providerConfigName` now required)

### Integration with crossplane-kubernetes
- [x] Reconcile gateway parentRef name — updated from `contour` to `eg` with `namespace: envoy-gateway-system` per crossplane-kubernetes response
- [x] Reconcile Prometheus service URL/namespace — confirmed `http://kube-prometheus-stack-prometheus.prometheus-system:9090` is correct
- [x] Process feature response from crossplane-kubernetes and update composition if needed — parentRef updated, Prometheus URL confirmed, PodMonitor handled by crossplane-kubernetes

## Dependencies

- **Upstream**: dot-kubernetes installing Envoy Gateway, KEDA, KEDA HTTP Add-on, and Prometheus on clusters
- **Required**: provider-kubernetes (`xpkg.crossplane.io/crossplane-contrib/provider-kubernetes`) — all composed resources are wrapped in Object CRs
- **Downstream**: crossplane-inference combined Gateway + KEDA PRD (will build on patterns established here)

## Decision Log

| Date | Decision | Rationale | Impact |
|------|----------|-----------|--------|
| 2026-02-22 | Implement Gateway API routing before KEDA scaling | Routing is more self-contained and establishes the KCL conditional resource generation pattern that KEDA work will reuse | Routing track is first priority; KEDA scaling follows |
| 2026-02-22 | Hardcode gateway parentRef name (`contour`) instead of adding a `gatewayName` XRD field | Minimizes API surface; crossplane-kubernetes Gateway support is being built in parallel and the actual gateway name may change | Follow-up task to reconcile with crossplane-kubernetes once Gateway support lands there |
| 2026-02-22 | crossplane-app and crossplane-kubernetes Gateway work proceeding in parallel | User is adding Gateway API support to crossplane-kubernetes concurrently | Gateway name in HTTPRoute parentRef may need updating once crossplane-kubernetes work is finalized |
| 2026-02-22 | Add Gateway API CRDs to test setup and rename KinD cluster to `dot-app` | CRDs required for Crossplane to create HTTPRoute resources; unique cluster name avoids conflicts with parallel projects | Gateway API routing tests now verified end-to-end in KinD |
| 2026-02-22 | Implement KEDA CPU/memory scaling first, defer Prometheus trigger to follow-up | CPU/memory is the core KEDA foundation; Prometheus is a separate trigger type that can be layered on afterward. Keeps scope focused and deliverable | Prometheus-related XRD fields, KCL logic, and tests moved to a deferred section in the progress tracker |
| 2026-02-22 | Move replica fields to top-level `spec.minReplicas`/`spec.maxReplicas` | Avoids field duplication — `minReplicas` serves as static replica count (scaling off) and scaling floor (scaling on). Keeps `scaling` object focused on *how* to scale, not *how many* | Replaces `spec.scaling.min`/`spec.scaling.max`; Deployment now explicitly sets `spec.replicas`; new "Replicas" task added before KEDA work |
| 2026-02-22 | Remove HPA entirely, use KEDA ScaledObject as only autoscaling mechanism | dot-kubernetes guarantees KEDA is installed; KEDA ScaledObject with CPU/memory triggers does exactly what HPA does. One scaling path is simpler to maintain and test than two | HPA generation removed from KCL; `scaling.type` field not needed for initial implementation (all scaling goes through KEDA); existing HPA tests replaced with KEDA ScaledObject tests |
| 2026-02-22 | Defer scale-to-zero test to Prometheus trigger phase | KEDA's admission webhook rejects `minReplicaCount: 0` with CPU/memory triggers because those metrics require running pods to be measurable. Scale-to-zero requires external metrics (queue depth, HTTP request rate, Prometheus queries) that exist independently of the workload | Scale-to-zero test moved from CPU/memory section to Prometheus section; `minReplicas: 0` in XRD remains valid for future use with external triggers |
| 2026-02-22 | Bring Prometheus trigger and scale-to-zero into PRD scope (no longer deferred) | Scale-to-zero is a core capability of KEDA-based scaling; deferring it leaves the scaling story incomplete. Prometheus is the production-standard approach for HTTP scale-to-zero with KEDA | Prometheus tasks moved from "Deferred" to active; Prometheus installed in test cluster; new XRD fields `scaling.type` and `scaling.prometheusAddress` added |
| 2026-02-22 | Use Prometheus trigger for scale-to-zero, reject KEDA HTTP Add-on | KEDA HTTP Add-on is beta (not recommended for production by KEDA project), introduces interceptor proxy in request path changing routing model (`Gateway → Interceptor → App`), uses different CRD (`HTTPScaledObject` vs `ScaledObject`), and complicates Gateway API integration. Prometheus trigger uses the same `ScaledObject`, no proxy, no routing changes, and Envoy Gateway metrics are observable at zero replicas | Prometheus trigger is the sole scale-to-zero mechanism; no `HTTPScaledObject` generation needed; routing composition unchanged |
| 2026-02-22 | Drop `spec.scaling.type` enum — use `prometheusAddress` presence as signal | Prometheus is the only alternative trigger type; a single-value enum is over-engineering. If future trigger types are added, a `type` field can be introduced then | No `scaling.type` field in XRD; KCL uses `_spec.scaling?.prometheusAddress` presence to select trigger type |
| 2026-02-22 | Use `envoy_http_downstream_rq_total` instead of `envoy_cluster_upstream_rq_total` | Envoy Gateway only creates backend cluster metrics when pods exist (chicken-and-egg problem at 0 replicas). The downstream listener metric counts requests arriving at the Gateway regardless of backend state | PromQL query changed in KCL and tests; metric is always available even at 0 pods |
| 2026-02-22 | Envoy Gateway cannot hold requests during scale-from-zero; cold-start 503s are a documented limitation | BackendTrafficPolicy retry/timeout policies do not help because Envoy short-circuits with 503 when there are 0 upstream endpoints — retry logic is never engaged | Cold-start section in PRD corrected; KubeElasti researched as potential solution but deferred to follow-up PRD |
| 2026-02-23 | Integrate KubeElasti into this PRD | Cold-start 503s are unacceptable for production scale-to-zero; KubeElasti is the best available solution (CNCF Sandbox, works at EndpointSlice level, coordinates with KEDA via pause/resume annotations) | New milestone added: install KubeElasti, generate ElastiService in KCL, verify manually, add tests, then request crossplane-kubernetes to install it on managed clusters |
| 2026-02-23 | Add `scaling.requestsPerReplica` field (default 100) | Prometheus trigger threshold was hardcoded to `"1"`, meaning KEDA would target 1 replica per req/s — far too aggressive for most applications. Users need to specify how many requests a single replica can handle so KEDA calculates desired replicas correctly (`metricValue / threshold`) | New XRD field `spec.scaling.requestsPerReplica`; KCL uses this as Prometheus trigger threshold; default 100 is reasonable for typical web services |
| 2026-02-23 | Abandon KubeElasti — incompatible with Crossplane | Three upstream bugs found: (1) `sync.Once` not reset on informer failure, (2) undocumented `triggers` field requirement, (3) `checkAndCreatePrivateService` uses `DeepCopy` which copies Crossplane's ownerReferences, then fails setting its own controller reference. Bug #3 is a fundamental incompatibility with any controller-managed Service | ElastiService removed from KCL composition; cold-start 503s during scale-from-zero accepted as known limitation; KubeElasti installation removed from crossplane-kubernetes feature request scope |
| 2026-02-23 | Switch Prometheus query from downstream to upstream metric | `envoy_http_downstream_rq_total` matches ALL workloads on the Gateway (per-listener, not per-app). `envoy_cluster_upstream_rq_total` with `envoy_cluster_name=~"httproute/<namespace>/<name>/.*"` scopes to a specific app using Envoy's cluster naming convention | PromQL query updated in KCL and tests; per-app scaling now works correctly; query uses `_namespace` and `_name` template variables |
| 2026-02-23 | Revisit KEDA HTTP Add-on as cold-start solution after KubeElasti failure | KubeElasti is incompatible with Crossplane (ownerReferences conflict). Research confirmed the KEDA HTTP Add-on does NOT have the same issue — it never touches user Services or EndpointSlices, only creates its own ScaledObject. Despite beta status and interceptor proxy trade-offs, it is the only viable cold-start solution for Crossplane-managed workloads | New milestone added: install HTTP Add-on, generate `HTTPScaledObject` in KCL, conditionally route HTTPRoute backendRef to interceptor when `minReplicas: 0`, verify manually, add tests, feature request to crossplane-kubernetes |
| 2026-02-23 | Add `external-push` trigger to ScaledObject for cold-start scaling | With `skip-scaledobject-creation`, the HTTP Add-on's external scaler has no ScaledObject trigger to act on. The Prometheus trigger alone cannot detect cold-start requests because the interceptor holds them before they reach the app (metric stays 0). Adding `external-push` as a second trigger in the same ScaledObject lets the interceptor's pending queue signal KEDA to scale from zero, while Prometheus handles steady-state scaling | ScaledObject now has dual triggers when `minReplicas: 0`; cold-start verified: HTTP 200 with `x-keda-http-cold-start: true`, ~3s latency |
| 2026-02-23 | Per-app ReferenceGrant generated by composition, not cluster-wide setup | ReferenceGrant in `keda` namespace allows HTTPRoutes to reference the interceptor Service cross-namespace. Originally a wildcard grant in `scripts/keda-http-addon.nu` setup, moved to per-app generation in the KCL composition (scoped to the app's namespace). However, Crossplane's `target: Default` places namespace-scoped composed resources in the XR's namespace — so for local deployments, the setup script's wildcard ReferenceGrant is still needed. Per-app ReferenceGrant only works correctly via Object wrapping (`_wrapped` path) | For local: wildcard ReferenceGrant in setup script. For remote (Object wrapping): per-app ReferenceGrant created in `keda` namespace via Object CR |
| 2026-02-23 | `targetNamespace` is optional, defaults to XR namespace | Original plan required `targetNamespace` as a required field. During implementation, defaulting to `_oxr.metadata.namespace` proved simpler — most users deploy resources in the same namespace as the XR. Remote-cluster deployments can override explicitly | `targetNamespace` removed from required fields; `_targetNamespace` defaults to `_oxr.metadata.namespace` in KCL |
| 2026-02-23 | Use `ClusterProviderConfig` instead of `ProviderConfig` | The namespace-scoped `.m.` API (`kubernetes.m.crossplane.io`) defaults to namespace-scoped `ProviderConfig`. Since the ProviderConfig must be accessible to Object CRs in any namespace, `ClusterProviderConfig` (cluster-scoped) is required. The `providerConfigRef` in the `_object` lambda must include `kind: ClusterProviderConfig` | `_object` lambda sets `providerConfigRef.kind = "ClusterProviderConfig"`; setup creates `ClusterProviderConfig` instead of `ProviderConfig` |
| 2026-02-23 | Frontend composition removed — backend handles all app types | Frontend was a subset of backend (different resource limits, `BACKEND_URL` env instead of DB vars, no scaling). Rather than maintaining two compositions, consolidated into backend with conditional `BACKEND_URL` support via `spec.frontend.backendUrl` | `package/frontend.yaml` deleted; `kcl/frontend.k` and `kcl/frontend-resources.k` deleted; frontend tests now use `type: backend` |
| 2026-02-23 | Consolidate scaling tests into single patch+assert cycle | Multiple sequential patch+assert cycles (gateway-api, replicas, scaling, prometheus, scale-to-zero) each waited for Crossplane reconciliation, making tests slow. Combined all scaling config into one patch and one comprehensive assertion | 11 test files deleted; single `scaling.yaml` and `assert-scaling.yaml` cover all scaling scenarios; backend test reduced from 8 to 3 patch+assert cycles |
| 2026-02-23 | Explicit App XR deletion in chainsaw `finally` blocks | Namespace-scoped Object CRs with provider-kubernetes finalizers cause deadlock during namespace deletion: provider-kubernetes tries to create `ProviderConfigUsage` but namespace is terminating. Explicit deletion of the App XR (which cascades to Object CRs) while the namespace is still Active prevents the deadlock | All chainsaw tests add `finally` block that deletes App XR and waits for Object CR cleanup before namespace deletion begins |
| 2026-02-23 | Gate KEDA HTTP Add-on resources on `routing == "gateway-api"` | HTTPScaledObject, external-push trigger, and interceptor backendRef only function when traffic flows through Gateway API HTTPRoute to the interceptor. With Ingress routing, the interceptor never receives traffic, making these resources useless | KCL conditions for these resources need `_spec.routing == "gateway-api"` added; test assertions updated accordingly |
| 2026-02-23 | Cross-namespace composed resources don't work with Crossplane `target: Default` | Verified in KinD: a ReferenceGrant with `namespace: keda` in the KCL output was created by Crossplane in the XR's namespace instead. Crossplane always overrides the namespace for namespace-scoped composed resources. Object wrapping (`kubernetes.m.crossplane.io/v1alpha1 Object`) solves this — the Object CR's `forProvider.manifest.metadata.namespace` is respected | ReferenceGrant only generated in `_wrapped` path; local deployments use wildcard from setup script |
| 2026-02-23 | ReferenceGrant must be per-app, not wildcard | Gateway API requires explicit `namespace` in `spec.from` — no wildcard support. crossplane-kubernetes confirmed they cannot create a universal ReferenceGrant since app namespaces are unknown ahead of time. Per-app ReferenceGrant must be created by the composition | ReferenceGrant generated as Object CR in `keda` namespace, scoped to the app's namespace |
| 2026-02-23 | Mandatory Object wrapping for all resources — no raw path | Per-app ReferenceGrant in `keda` namespace requires Object wrapping (Crossplane's `target: Default` overrides namespace on composed resources). Rather than maintaining two code paths (`_raw`/`_wrapped`), wrap ALL resources in Object CRs unconditionally. This makes cold-start work on every cluster (same-cluster via `InjectedIdentity` ProviderConfig, remote via remote ProviderConfig) and simplifies the composition to a single path | `providerConfigName` and `targetNamespace` are required fields (no defaults); provider-kubernetes is a hard dependency; all `krm.kcl.dev` annotation-based resource creation removed; major version bump required |
