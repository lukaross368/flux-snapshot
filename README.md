# flux-snapshot

## Problem Statement

When a Flux reconciliation fails, each object reports only its own error in isolation. There is no record of the full dependency chain state at the moment of failure — which upstream Kustomization was degraded, which HelmRelease was mid-upgrade, which resource was missing.

Flux keeps retrying. States get overwritten. Kubernetes events expire after around an hour<sup>[1]</sup>. By the time someone investigates, the context that would explain the failure is gone.

Recent Flux releases introduced some improvements here — v2.7 added reconciliation history and OpenTelemetry tracing<sup>[2]</sup>, and the OTel tracing RFC<sup>[3]</sup> formalised how spans are collected and forwarded. These tell you *that* something failed and *when*. What they don't tell you is why the conditions existed across the dependency chain that caused it to fail in the first place. This is an explicit non-goal of the RFC<sup>[3]</sup>.


## Approach

`flux-snapshot` is an observe-only controller deployed alongside Flux. It does not modify or extend Flux's controllers; it watches the existing reconciliation objects and, the moment one fails, captures a dependency-aware, point-in-time record of the surrounding chain.

For each object in the failed chain — the failed object, its dependencies, the source it reconciles from, and the resources it manages — the snapshot records its identity, its status conditions (type, status, reason, message, transition time), its observed vs. desired generation, any resolved source revision, and the Kubernetes events attached to it. Structurally it is a small graph: one node per object holding that state, edges for the dependency relationships, and a single timeline of condition transitions ordered across the chain — the causal sequence retries overwrite and that v2.7 reconciliation history and OpenTelemetry tracing omit.

Each snapshot is one self-contained structured document (JSON), keyed by failed object and capture time. The natural home is object storage: one record per incident, durable and outside the cluster's transient state and ~1h event TTL. A lightweight index — or a thin custom resource pointing at each record — makes incidents queryable by object, time, or likely root cause; records could equally be shipped to an existing log store to sit alongside other telemetry.


## What it looks like

A GitRepository loses authentication and cascades into three Kustomizations. This is what the operator sees (real capture from the test cluster):

```
$ kubectl get kustomizations -n flux-system
NAME    AGE   READY   STATUS
app-a   78s   False   Source artifact not found, retrying in 30s
app-b   78s   False   Source artifact not found, retrying in 30s
infra   78s   False   Source artifact not found, retrying in 30s
```

Three identical symptoms, none of which mention the cause — that lives on a different resource type, reachable only by manually walking conditions → `dependsOn` → `sourceRef` → events before the trail expires ([test/e2e/control.sh](test/e2e/control.sh) scripts that six-step hunt for comparison).

The moment `app-a` fails, flux-snapshot emits (abridged real output):

```json
{ "msg": "root cause", "details": {
    "trigger":  "app-a",
    "object":   "broken-source",
    "kind":     "GitRepository",
    "reason":   "GitOperationFailed",
    "message":  "failed to checkout and determine revision: unable to clone 'https://github.com/flux-snapshot-test/platform-config': authentication required",
    "duration": "24s" }}

{ "msg": "affected chain",
  "chain": "app-a(Kustomization) → infra(Kustomization) → broken-source(GitRepository)" }

{ "msg": "warning event", "object": "broken-source", "reason": "GitOperationFailed", "count": 5 }
```

`app-b` and `infra` fail with the same root cause and are deduplicated — one incident, one notification, with the cascade path and the originating error attached.


## Status

Development is iterative and acceptance-test-first: each iteration is specified as end-to-end test cases ([docs/test-cases.md](docs/test-cases.md)) that run against a real Flux installation on kind and fail until the iteration is implemented.

- ✅ **Iteration 1** — failing-Kustomization detector running on kind
- ✅ **Iteration 2** — dependency-chain traversal, root-cause identification, per-root-cause dedup (e2e cases 1–3 green)
- 🚧 **Iteration 3** — HelmRelease/HelmRepository support and cross-type chains via chart-from-git and `healthChecks` (e2e cases 4–6 written and red; [tickets](docs/iteration-3-tickets.md))
- ⬜ **Production guarantees** — implement and verify the five properties below
- ⬜ **CI/CD** — lint plus the kind e2e suite in GitHub Actions


## Guarantees

The controller is only safe to run in a shared production cluster if it holds all of the following. Each is a property the design must guarantee, not a feature. These are design requirements that constrain every iteration; their implementation and verification is a dedicated iteration of its own (see Status):

1. **It cannot harm Flux.** Strictly observational, with no capability to affect reconciliation. If the controller fails or is removed, Flux is wholly unaffected.
2. **It cannot amplify an incident.** It activates during failure, so its own resource use and load on the cluster must stay bounded under a cascading failure and never add pressure to an already-stressed cluster.
3. **It cannot leak.** Least-privilege access only; captured data fails safe by default, so sensitive content is never persisted.
4. **It proves it works.** Its own health — and, critically, whether it is actually capturing — must be observable and alertable. End-to-end capture is continuously verified, not assumed.
5. **It stays available when it matters.** It must survive node disruption and reclamation so that it is running at the moment a failure occurs, and run hardened with least privilege at the workload level.

---

### References

1. [Kubernetes Event API — default TTL ~1 hour](https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/)
2. [Announcing Flux v2.7 GA](https://fluxcd.io/blog/2025/09/flux-v2.7.0/)
3. [RFC-0011: OpenTelemetry Tracing](https://github.com/fluxcd/flux2/tree/main/rfcs/0011-opentelemetry-tracing)
