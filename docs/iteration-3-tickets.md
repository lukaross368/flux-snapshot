# Iteration 3 Tickets — HelmRelease & Cross-Type Chain Support

Acceptance criteria: `test/e2e/case4_chart_from_git.sh`, `case5_helm_chain_healthcheck.sh`,
and `case6_mixed_stack.sh` go green while cases 1–3 stay green.

Current red state (verified on kind, 2026-06-12):

- **TC4**: 0 notifications — nothing watches HelmReleases.
- **TC5**: root cause reported as `tc5-app-config(Kustomization)/HealthCheckFailed` (the
  trigger itself) instead of `tc5-company-charts(HelmRepository)` — `healthChecks` is not
  traversed, so the graph's only leaf is the healthy GitRepository and `RootCause()` falls
  back to the timeline. Chain stops at `tc5-app-config → tc5-app-git`.
- **TC6**: 2 notifications instead of 1 — `tc6-ingress-config` and `tc6-cert-manager-crds`
  resolve to different root-cause keys because the ingress chain can't reach
  `tc6-platform-git` without healthCheck + HR traversal. Healthy `tc6-apps-git` appears in
  a chain string.

Suggested order below; T1→T2 are prep, T3–T5 are the core, T6–T7 close the remaining
assertions.

---

## T1 — Register Helm types

**Goal:** the manager can decode HelmReleases.

- Add `github.com/fluxcd/helm-controller/api` (v2) to `go.mod`.
- Register `helmv2.AddToScheme` in `cmd/manager/main.go` alongside the existing schemes.

**Done when:** `go build ./...` passes with the new import; a `c.Get` of a HelmRelease in a
unit test decodes into `helmv2.HelmRelease`.

**Gotcha:** pick the helm-controller api version compatible with the
`sigs.k8s.io/controller-runtime` and `k8s.io/*` versions already in `go.mod` — let
`go get` resolve it rather than pinning blindly.

---

## T2 — Notifier seam (prep, makes T3–T5 unit-testable)

**Goal:** tests can assert "notified exactly once with this snapshot" instead of poking at
`lastNotified` internals.

- Define a small interface in `internal/controller` (e.g. `type Notifier interface {
  Notify(snapshot.Snapshot) }`), inject it into `SnapshotReconciler`, default to the
  existing log-based implementation.
- Rewrite the existing controller tests to assert against a recording fake.

**Done when:** `TestReconcile_FailingKS_NotifiesOnce` asserts on recorded notifications,
not map length.

---

## T3 — Generalize the snapshot builder entry point

**Goal:** `snapshot.Build` accepts either a Kustomization or a HelmRelease as the trigger.

Today `Build(ctx, c, *kustomizev1.Kustomization)` is KS-only and the recursion
(`buildDependencyGraph`) is typed to Kustomization. Options: a node-fetcher per kind
dispatched on GVK, or convert everything to `unstructured` at the boundary. Either way the
`visited` map and `objectKey` (already group+kind qualified) carry over unchanged.

**Done when:** `Build` can start from an HR trigger; existing builder unit tests still
pass; new unit test builds a snapshot from a failing HR fixture.

---

## T4 — New traversal edges

**Goal:** the graph walk follows all iteration 3 edge types.

| From | Field | To | Edge type |
|---|---|---|---|
| HelmRelease | `spec.dependsOn[]` | HelmRelease (same kind only!) | `dependsOn` |
| HelmRelease | `spec.chart.spec.sourceRef` | HelmRepository **or** GitRepository | `sourceRef` |
| Kustomization | `spec.healthChecks[]` (Flux kinds only) | HelmRelease | `healthCheck` |

- Namespace defaulting: all three references default to the parent object's namespace
  when unset (`dependsOn` entries and `chart.spec.sourceRef` have optional namespaces;
  `healthChecks` entries carry an explicit namespace field).
- `healthChecks` entries for non-Flux kinds (Deployment, Service, …) are skipped — check
  the entry's `apiVersion` group, don't fetch.
- `fetchSourceNode` currently hardcodes `source.toolkit.fluxcd.io/v1` + the KS sourceRef
  shape; HelmRepository lives in the same group so it can be reused, but the HR chart
  sourceRef sits one level deeper (`spec.chart.spec.sourceRef`).

**Done when (e2e):** TC5's `assert_root_cause tc5-company-charts HelmRepository` and the
chain-contains assertions for `tc5-api-server`/`tc5-postgresql` pass; TC5/TC6 warning-event
assertions pass (events attach once the objects are graph nodes).

---

## T5 — Watch HelmReleases

**Goal:** HelmReleases trigger snapshots, and dedup spans both kinds.

- Register a second controller (`For(&helmv2.HelmRelease{})`) sharing the **same**
  reconciler state — `lastNotified` must be one map across both watchers or TC6's
  "4 failing objects → 1 notification" can't hold.
- The Ready=False check is identical (`fluxmeta.ReadyCondition`).

**Done when (e2e):** TC4 fully green (it cannot pass without this); TC6's
`assert_msg_count "root cause" 1` and single-trigger assertion pass.

---

## T6 — ChainSummary = path from trigger to root cause

**Goal:** the `chain` string is the walk from trigger to root cause, not the node list in
append order.

Today `ChainSummary` joins **all** nodes, so healthy side nodes (`tc5-app-git`,
`tc6-apps-git`) leak in and fan-in branches would print as a fake linear chain. Compute
the path over `Edges` from `Trigger` to `RootCause().Object` instead. Healthy leaves stay
in `Nodes` (the snapshot keeps full context) — they just don't appear in the path string.

**Done when (e2e):** TC5's `assert_chain_excludes tc5-app-git` and TC6's
`assert_chain_excludes tc6-apps-git` pass while chain-contains assertions stay green.

---

## T7 — Match events by kind + namespace, not name alone

**Goal:** events are attached to the right node.

`Build` currently matches events on `involvedObject.name` only. TC4–TC6 put
Kustomizations, HelmReleases, and sources in the same namespace; a name collision across
kinds would attach foreign events. Match on `involvedObject.kind` + `namespace` + `name`.

**Done when:** unit test with two same-named objects of different kinds attaches each
event to the correct node.

---

## T8 (pulled forward, small) — Make the CI lint job lint

The `lint` job in `.github/workflows/ci.yml` checks out and sets up Go, then ends. Add the
`golangci-lint` action (the repo already has `.golangci.yml`). Worth doing before the Go
work in T1–T6 so it catches issues during the iteration.

---

## Discovered along the way (already encoded in fixtures/docs)

- Cross-kind `dependsOn` does not exist in Flux — see the design correction at the top of
  the iteration 3 section in `docs/test-cases.md`.
- A Kustomization with a permanently failing health check and default `retryInterval`
  never stably reports `Ready=False` (reconcile loop runs back-to-back). Fixtures set
  `retryInterval: 2m`. Implication for the controller: KS health-check failures are only
  observable when users set a sane `retryInterval` — worth a README note in the
  guarantees iteration.
