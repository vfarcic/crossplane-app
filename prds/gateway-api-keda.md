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

**Behavior**:
- `scaling.enabled: false` (default) → Deployment gets `spec.replicas: minReplicas`; `maxReplicas` is ignored
- `scaling.enabled: true` → Deployment does **not** set `spec.replicas` (KEDA manages replica count); generates a KEDA ScaledObject with CPU and memory triggers using `minReplicas`/`maxReplicas`
- `minReplicas: 0` → enables scale-to-zero (KEDA handles idle period detection)

### Discussion: Which scaling API approach? — **Resolved**

Start with KEDA ScaledObject as the only autoscaling mechanism (no HPA). The `scaling.type` field will be used later to select trigger types (e.g., Prometheus) but is not needed for the initial CPU/memory implementation.

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

### XRD Changes

Extend `package/definition.yaml` with:
- `spec.routing` enum field (`ingress`, `gateway-api`)
- `spec.minReplicas` (integer, minimum 0, default 1) — replaces `spec.scaling.min`
- `spec.maxReplicas` (integer, default 10) — replaces `spec.scaling.max`
- Remove `spec.scaling.min` and `spec.scaling.max` (moved to top level)
- Remove `spec.scaling.type` (not needed until Prometheus trigger is added)

### Backward Compatibility

- Default `routing` to `ingress` — existing XRs continue to work unchanged
- Default `minReplicas: 1` and `maxReplicas: 10` — matches current scaling defaults
- HPA removed entirely — `scaling.enabled: true` now generates KEDA ScaledObject instead of HPA (requires KEDA on cluster, guaranteed by dot-kubernetes)
- Deployment now explicitly sets `spec.replicas` from `minReplicas` when scaling is disabled (previously relied on Kubernetes default)

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
- **Replicas: static** — Deployment gets `spec.replicas` from `minReplicas` when scaling disabled
- **Scaling: KEDA CPU/memory** — ScaledObject with CPU and memory triggers, no `spec.replicas` on Deployment
- **Scaling: min 0** — ScaledObject with `minReplicaCount: 0`
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
- [ ] KCL: KEDA ScaledObject generation with CPU/memory triggers using `minReplicas`/`maxReplicas`
- [ ] Tests: KEDA CRDs added to test setup
- [ ] Tests: KEDA CPU/memory scaling test
- [ ] Tests: Scale-to-zero (minReplicas: 0) test
- [ ] Tests: Combined Gateway API routing + KEDA scaling test

### Scaling (KEDA — Prometheus) — Deferred
- [ ] XRD: Add `prometheus` to `spec.scaling.type` enum
- [ ] XRD: `spec.scaling.prometheusAddress` field
- [ ] KCL: KEDA ScaledObject generation with Prometheus trigger
- [ ] Tests: KEDA Prometheus scaling test

## Dependencies

- **Upstream**: dot-kubernetes installing Envoy Gateway and KEDA on clusters
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
