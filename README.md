# flux-snapshot

## Problem Statement

When a Flux reconciliation fails, each object reports only its own error in isolation. There is no record of the full dependency chain state at the moment of failure — which upstream Kustomization was degraded, which HelmRelease was mid-upgrade, which resource was missing.

Flux keeps retrying. States get overwritten. Kubernetes events expire after around an hour<sup>[1]</sup>. By the time someone investigates, the context that would explain the failure is gone.

Recent Flux releases introduced some improvements here — v2.7 added reconciliation history and OpenTelemetry tracing<sup>[2]</sup>, and the OTel tracing RFC<sup>[3]</sup> formalised how spans are collected and forwarded. These tell you *that* something failed and *when*. What they don't tell you is why the conditions existed across the dependency chain that caused it to fail in the first place. This is an explicit non-goal of the RFC<sup>[3]</sup>.

In practice this means post-incident analysis of GitOps failures relies on either being present at the moment it happened, or piecing things together from incomplete evidence after the fact. Neither is good enough when you're running a shared platform with complex dependency graphs that other teams depend on.

**This project captures and persists a dependency-aware snapshot at the moment a Flux reconciliation fails — so the full picture is available when you need it, not just when it happens.**

---

### References

1. [Kubernetes Event API — default TTL ~1 hour](https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/)
2. [Announcing Flux v2.7 GA](https://fluxcd.io/blog/2025/09/flux-v2.7.0/)
3. [RFC-0011: OpenTelemetry Tracing](https://github.com/fluxcd/flux2/tree/main/rfcs/0011-opentelemetry-tracing)
