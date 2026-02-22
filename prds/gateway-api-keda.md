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

**Metric source**: Use KEDA's Prometheus trigger pointing at Envoy Gateway's **downstream listener metrics** (`envoy_http_downstream_rq_total`). The gateway listener runs independently of application pods, so this metric remains observable at zero replicas. Initially we tried `envoy_cluster_upstream_rq_total`, but discovered that Envoy only creates backend cluster metrics when pods exist — a chicken-and-egg problem. The downstream listener metric (`envoy_http_conn_manager_prefix=~"http-.*"`) counts all requests arriving at the Gateway regardless of backend state. This uses the same `ScaledObject` resource as CPU/memory scaling — just a different trigger type — keeping the composition simple.

**Why not KEDA HTTP Add-on**: Evaluated and rejected. While actively developed (v0.12.2, Feb 2026), it is beta with the KEDA project explicitly stating it's not recommended for production. More importantly, it introduces architectural complexity: an interceptor proxy in the request path (changing `Gateway → App` to `Gateway → Interceptor → App`), a different CRD (`HTTPScaledObject` instead of `ScaledObject`), and direct interaction with Gateway API routing configuration. The Prometheus approach avoids all of this.

**Cold start and request handling**: When KEDA scales from zero, there is a window (~15-30s) where no pods are available. During manual testing, we confirmed that Envoy Gateway returns **503 immediately** when there are zero upstream endpoints — it short-circuits before retry logic is engaged, so BackendTrafficPolicy retry/timeout policies **do not help**. This is a fundamental Envoy behavior, not a configuration issue.

**KubeElasti** (CNCF Sandbox) is the chosen solution: it manipulates EndpointSlices to redirect traffic to a resolver proxy during scale-from-zero, queuing requests until pods are ready. It coordinates with KEDA via annotations (pausing/resuming ScaledObject). The composition will generate an `ElastiService` alongside the ScaledObject when `minReplicas: 0`.

### Discussion: Which scaling API approach? — **Resolved**

Start with KEDA ScaledObject as the only autoscaling mechanism (no HPA). The presence of `scaling.prometheusAddress` selects Prometheus trigger; omitting it defaults to CPU/memory triggers. No `scaling.type` enum needed — Prometheus is currently the only alternative trigger, so a single-value enum would be over-engineering.

### Discussion: Where do replica fields live? — **Resolved**

`minReplicas` and `maxReplicas` are top-level `spec` fields rather than nested under `scaling`. This avoids field duplication: `minReplicas` serves as both the static replica count (scaling off) and the scaling floor (scaling on). The `scaling` object is purely about *how* to scale, not *how many*.

## Implementation Approach

### KCL Changes

Modify `kcl/backend-resources.k` to:

1. **Routing**: Add conditional resource generation based on `spec.routing`:
   - `routing: ingress` (or unset) → generate `Ingress` (current behavior)
   - `routing: gateway-api` → generate `HTTPRoute` referencing the default `Gateway`

2. **Scaling**: Replace HPA with KEDA ScaledObject:
   - Remove HPA generation entirely
   - When `scaling.enabled: true` → generate `keda.sh/v1alpha1 ScaledObject` with CPU and memory triggers
   - ScaledObject targets the Deployment by name
   - `minReplicas`/`maxReplicas` passed to ScaledObject

3. **Prometheus trigger**: Add Prometheus-based scaling for scale-to-zero:
   - When `scaling.prometheusAddress` is set → generate ScaledObject with Prometheus trigger instead of CPU/memory triggers
   - PromQL query: `sum(rate(envoy_http_downstream_rq_total{envoy_http_conn_manager_prefix=~"http-.*"}[2m]))` — downstream listener metric observable without running pods
   - `prometheusAddress` specifies the Prometheus server URL
   - `requestsPerReplica` (default 100) used as Prometheus trigger `threshold` — KEDA calculates desired replicas as `metricValue / threshold`
   - Enables `minReplicas: 0` for scale-to-zero

### XRD Changes

Extend `package/definition.yaml` with:
- `spec.routing` enum field (`ingress`, `gateway-api`)
- `spec.minReplicas` (integer, minimum 0, default 1) — replaces `spec.scaling.min`
- `spec.maxReplicas` (integer, default 10) — replaces `spec.scaling.max`
- `spec.scaling.prometheusAddress` (string) — Prometheus server URL; when set, selects Prometheus trigger instead of CPU/memory; required for `minReplicas: 0`
- `spec.scaling.requestsPerReplica` (integer, default 100) — requests per second each replica can handle; used as KEDA Prometheus trigger threshold; only applies when `prometheusAddress` is set
- Remove `spec.scaling.min` and `spec.scaling.max` (moved to top level)

### Backward Compatibility

- Default `routing` to `ingress` — existing XRs continue to work unchanged
- Default `minReplicas: 1` and `maxReplicas: 10` — matches current scaling defaults
- HPA removed entirely — `scaling.enabled: true` now generates KEDA ScaledObject instead of HPA (requires KEDA on cluster, guaranteed by dot-kubernetes)
- Deployment now explicitly sets `spec.replicas` from `minReplicas` when scaling is disabled (previously relied on Kubernetes default)

## Testing

### KinD Test Environment

This is designed to be fully testable in a local KinD cluster:

1. Install KEDA and Envoy Gateway via Helm in the test cluster setup
2. Install Prometheus (kube-prometheus-stack or similar) for Prometheus trigger tests
3. Create a `Gateway` resource with HTTP listener
4. Deploy a test application via the App XR with `routing: gateway-api`
5. Assert `HTTPRoute` is created with correct parentRef and backendRef
6. Deploy with `scaling.enabled: true`
7. Assert `ScaledObject` is created with correct triggers and target
8. Deploy with `scaling.prometheusAddress` and `minReplicas: 0`
9. Assert `ScaledObject` is created with Prometheus trigger and `minReplicaCount: 0`

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
- [ ] Reconcile gateway parentRef name with crossplane-kubernetes

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
- [x] KCL: ScaledObject generation with Prometheus trigger when `prometheusAddress` is set — query uses `envoy_http_downstream_rq_total` downstream listener metric
- [x] KCL: Validate `minReplicas: 0` requires `scaling.prometheusAddress` (CPU/memory triggers cannot support scale-to-zero)
- [x] Tests: Install Prometheus (kube-prometheus-stack) in test cluster setup
- [x] Tests: Prometheus trigger scaling test — assert ScaledObject with correct trigger type, serverAddress, and query
- [x] Tests: Scale-to-zero test — assert ScaledObject with `minReplicaCount: 0` and Prometheus trigger
- [x] Manual verification: scale-to-zero and scale-from-zero confirmed working in KinD with Envoy Gateway + KEDA + Prometheus
- [ ] Reconcile Prometheus service URL/namespace with crossplane-kubernetes (currently `http://kube-prometheus-stack-prometheus.prometheus-system:9090`)
- [ ] XRD: Add `spec.scaling.requestsPerReplica` field (integer, default 100)
- [ ] KCL: Use `requestsPerReplica` as Prometheus trigger threshold (currently hardcoded to `"1"`)
- [ ] Tests: Update Prometheus scaling tests to assert configurable threshold

### Cold-Start Request Handling (KubeElasti)
- [x] Investigate Envoy Gateway retry/timeout policies — confirmed NOT viable (Envoy 503s immediately with 0 endpoints)
- [x] Research KubeElasti (CNCF Sandbox) as cold-start solution
- [x] Install KubeElasti in test cluster setup
- [x] KCL: Generate `ElastiService` CRD alongside ScaledObject when `minReplicas: 0`
- [ ] Manual verification: deploy app with scale-to-zero, confirm requests are queued during scale-from-zero instead of 503
- [x] Tests: Chainsaw test for ElastiService generation
- [ ] Feature request to crossplane-kubernetes to install KubeElasti on managed clusters

### Integration with crossplane-kubernetes
- [ ] Reconcile gateway parentRef name (currently hardcoded `contour`)
- [ ] Reconcile Prometheus service URL/namespace
- [ ] Process feature response from crossplane-kubernetes and update composition if needed

## Dependencies

- **Upstream**: dot-kubernetes installing Envoy Gateway, KEDA, and Prometheus on clusters
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
