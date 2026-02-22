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

### Scaling

Replace HPA with KEDA ScaledObject when KEDA-based scaling is requested:

```yaml
spec:
  scaling:
    enabled: true
    min: 1          # minimum replicas (default: 1, can be 0 for scale-to-zero)
    max: 10         # maximum replicas (default: 10)
    triggers:       # optional, defaults to CPU/memory if not specified
    - type: prometheus
      metadata:
        serverAddress: http://prometheus.monitoring:9090
        query: sum(rate(http_requests_total{app="my-app"}[2m]))
        threshold: "100"
    - type: cpu
      metadata:
        value: "80"
```

**Behavior**:
- If `triggers` is not specified: generate a KEDA ScaledObject with CPU and memory triggers (same behavior as current HPA, but through KEDA)
- If `triggers` is specified: use the provided triggers
- `min: 0` enables scale-to-zero (KEDA handles the idle period detection)

**Alternative (simpler) API** — if full trigger customization is too much:

```yaml
spec:
  scaling:
    enabled: true
    min: 1
    max: 10
    type: cpu-memory | prometheus  # default: cpu-memory
    prometheusAddress: http://prometheus.monitoring:9090  # only if type: prometheus
```

### Discussion: Which API approach? — **Resolved**

The simpler API is easier to use but less flexible. The trigger-based API mirrors KEDA's native model and avoids having to add new fields for every trigger type. **Decision**: Start with the simpler API (`scaling.type: cpu-memory | prometheus`) for this PRD, extend to trigger-based API later if users need custom triggers.

## Implementation Approach

### KCL Changes

Modify `kcl/backend-resources.k` to:

1. **Routing**: Add conditional resource generation based on `spec.routing`:
   - `routing: ingress` (or unset) → generate `Ingress` (current behavior)
   - `routing: gateway-api` → generate `HTTPRoute` referencing the default `Gateway`

2. **Scaling**: Replace HPA generation with KEDA ScaledObject:
   - When `scaling.enabled: true` → generate `keda.sh/v1alpha1 ScaledObject`
   - ScaledObject targets the Deployment by name
   - Triggers derived from `scaling.type` or `scaling.triggers`
   - Remove HPA generation (or keep as fallback when KEDA is not available)

### XRD Changes

Extend `package/definition.yaml` with:
- `spec.routing` enum field (`ingress`, `gateway-api`)
- `spec.scaling.type` or `spec.scaling.triggers` (depending on API choice)
- `spec.scaling.min` allowing value `0` (currently minimum is 1)

### Backward Compatibility

- Default `routing` to `ingress` — existing XRs continue to work unchanged
- Default `scaling.type` to `cpu-memory` — existing scaling behavior preserved
- HPA-based scaling could remain as fallback for clusters without KEDA

## Testing

### KinD Test Environment

This is designed to be fully testable in a local KinD cluster:

1. Install KEDA and Envoy Gateway via Helm in the test cluster setup
2. Create a `Gateway` resource with HTTP listener
3. Deploy a test application via the App XR with `routing: gateway-api`
4. Assert `HTTPRoute` is created with correct parentRef and backendRef
5. Deploy with `scaling.enabled: true`
6. Assert `ScaledObject` is created with correct triggers and target

No GPUs, no cloud resources, no inference stack — just standard Kubernetes resources.

### Test Cases

- **Routing: Ingress (default)** — existing behavior, no regression
- **Routing: Gateway API** — HTTPRoute generated, Ingress not generated
- **Scaling: HPA fallback** — when KEDA is not available (or explicitly requested)
- **Scaling: KEDA CPU/memory** — ScaledObject with CPU and memory triggers
- **Scaling: KEDA Prometheus** — ScaledObject with Prometheus trigger
- **Scaling: min 0** — ScaledObject with `minReplicaCount: 0`
- **Combined** — Gateway API routing + KEDA scaling together

## Lessons for crossplane-inference

This PRD explicitly serves as a precursor to the inference-specific implementation. Key transferable patterns:

- **KCL patterns for conditional resource generation** (Ingress vs HTTPRoute, HPA vs ScaledObject)
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

### Scaling (KEDA)
- [ ] XRD: `spec.scaling.type` field (`cpu-memory`, `prometheus`)
- [ ] XRD: Allow `spec.scaling.min: 0` for scale-to-zero
- [ ] KCL: KEDA ScaledObject generation with CPU/memory triggers
- [ ] KCL: KEDA ScaledObject generation with Prometheus trigger
- [ ] Tests: KEDA CPU/memory scaling test
- [ ] Tests: KEDA Prometheus scaling test
- [ ] Tests: Scale-to-zero (min: 0) test
- [ ] Tests: Combined Gateway API routing + KEDA scaling test

## Dependencies

- **Upstream**: dot-kubernetes installing Envoy Gateway and KEDA on clusters
- **Downstream**: crossplane-inference combined Gateway + KEDA PRD (will build on patterns established here)

## Decision Log

| Date | Decision | Rationale | Impact |
|------|----------|-----------|--------|
| 2026-02-22 | Implement Gateway API routing before KEDA scaling | Routing is more self-contained and establishes the KCL conditional resource generation pattern that KEDA work will reuse | Routing track is first priority; KEDA scaling follows |
| 2026-02-22 | Hardcode gateway parentRef name (`contour`) instead of adding a `gatewayName` XRD field | Minimizes API surface; crossplane-kubernetes Gateway support is being built in parallel and the actual gateway name may change | Follow-up task to reconcile with crossplane-kubernetes once Gateway support lands there |
| 2026-02-22 | crossplane-app and crossplane-kubernetes Gateway work proceeding in parallel | User is adding Gateway API support to crossplane-kubernetes concurrently | Gateway name in HTTPRoute parentRef may need updating once crossplane-kubernetes work is finalized |
