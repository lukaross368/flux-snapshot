package snapshot

import (
	"context"
	"testing"
	"time"

	kustomizev1 "github.com/fluxcd/kustomize-controller/api/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func newScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := kustomizev1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func cond(condType string, status metav1.ConditionStatus, reason, msg string, at time.Time) metav1.Condition {
	return metav1.Condition{
		Type:               condType,
		Status:             status,
		Reason:             reason,
		Message:            msg,
		LastTransitionTime: metav1.NewTime(at),
	}
}

func failedCond(reason, msg string, at time.Time) metav1.Condition {
	return cond("Ready", metav1.ConditionFalse, reason, msg, at)
}

func makeKS(name, ns, sourceKind, sourceName string, deps []kustomizev1.DependencyReference, conditions []metav1.Condition) *kustomizev1.Kustomization {
	return &kustomizev1.Kustomization{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Generation: 1},
		Spec: kustomizev1.KustomizationSpec{
			SourceRef: kustomizev1.CrossNamespaceSourceReference{Kind: sourceKind, Name: sourceName},
			DependsOn: deps,
		},
		Status: kustomizev1.KustomizationStatus{
			Conditions:         conditions,
			ObservedGeneration: 1,
		},
	}
}

func sourceObj(kind, name, ns string, rawConds []interface{}) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "source.toolkit.fluxcd.io/v1",
		"kind":       kind,
		"metadata": map[string]interface{}{
			"name":       name,
			"namespace":  ns,
			"generation": int64(1),
		},
		"status": map[string]interface{}{
			"observedGeneration": int64(1),
			"conditions":         rawConds,
		},
	}}
}

func failedGR(name, ns string) *unstructured.Unstructured {
	return sourceObj("GitRepository", name, ns, []interface{}{
		map[string]interface{}{
			"type":               "Ready",
			"status":             "False",
			"reason":             "GitOperationFailed",
			"message":            "auth failed",
			"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
		},
	})
}

func TestObjectKey(t *testing.T) {
	ref := ObjectRef{Group: "g", Kind: "K", Namespace: "ns", Name: "n"}
	if got, want := objectKey(ref), "g/K/ns/n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestChainSummary(t *testing.T) {
	s := Snapshot{Nodes: []Node{
		{Ref: ObjectRef{Name: "app", Kind: "Kustomization"}},
		{Ref: ObjectRef{Name: "src", Kind: "GitRepository"}},
	}}
	want := "app(Kustomization) → src(GitRepository)"
	if got := s.ChainSummary(); got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestChainSummary_Empty(t *testing.T) {
	if got := (Snapshot{}).ChainSummary(); got != "" {
		t.Fatalf("expected empty string, got %q", got)
	}
}

func TestBuildTimeline_Sorted(t *testing.T) {
	t1 := time.Now().Add(-2 * time.Minute)
	t2 := time.Now().Add(-1 * time.Minute)
	t3 := time.Now()

	nodes := []Node{
		{Ref: ObjectRef{Name: "b"}, Conditions: []metav1.Condition{
			cond("Ready", metav1.ConditionFalse, "R", "", t2),
		}},
		{Ref: ObjectRef{Name: "a"}, Conditions: []metav1.Condition{
			cond("Ready", metav1.ConditionFalse, "R", "", t1),
			cond("Reconciling", metav1.ConditionTrue, "R", "", t3),
		}},
	}

	tl := buildTimeline(nodes)
	if len(tl) != 3 {
		t.Fatalf("expected 3 transitions, got %d", len(tl))
	}
	if !tl[0].Time.Equal(t1) {
		t.Error("first entry should be earliest")
	}
	if !tl[2].Time.Equal(t3) {
		t.Error("last entry should be latest")
	}
}

func TestBuildTimeline_Empty(t *testing.T) {
	if tl := buildTimeline(nil); len(tl) != 0 {
		t.Fatalf("expected empty timeline, got %d entries", len(tl))
	}
}

func TestRootCause_LeafNode(t *testing.T) {
	t1 := time.Now()
	ksRef := ObjectRef{Name: "ks", Kind: "Kustomization", Group: "kustomize.toolkit.fluxcd.io"}
	grRef := ObjectRef{Name: "gr", Kind: "GitRepository", Group: "source.toolkit.fluxcd.io"}

	s := Snapshot{
		Nodes: []Node{
			{Ref: ksRef, Conditions: []metav1.Condition{failedCond("ArtifactFailed", "cascade", t1)}},
			{Ref: grRef, Conditions: []metav1.Condition{failedCond("GitOperationFailed", "auth", t1)}},
		},
		Edges: []Edge{{From: ksRef, To: grRef, Type: "sourceRef"}},
	}

	rc := s.RootCause()
	if rc == nil {
		t.Fatal("expected root cause, got nil")
	}
	if rc.Object.Name != "gr" {
		t.Errorf("expected gr as root cause, got %s", rc.Object.Name)
	}
	if rc.Condition.Reason != "GitOperationFailed" {
		t.Errorf("unexpected reason: %s", rc.Condition.Reason)
	}
}

// Leaf exists but has no Ready condition — fall back to earliest in timeline.
func TestRootCause_FallsBackToTimeline(t *testing.T) {
	t1 := time.Now().Add(-time.Minute)
	ksRef := ObjectRef{Name: "ks", Kind: "Kustomization"}
	grRef := ObjectRef{Name: "gr", Kind: "GitRepository"}

	s := Snapshot{
		Nodes: []Node{
			{Ref: ksRef, Conditions: []metav1.Condition{failedCond("ArtifactFailed", "", t1)}},
			{Ref: grRef, Conditions: nil},
		},
		Edges:    []Edge{{From: ksRef, To: grRef, Type: "sourceRef"}},
		Timeline: []ConditionTransition{{Time: t1, Object: ksRef, Condition: failedCond("ArtifactFailed", "", t1)}},
	}

	rc := s.RootCause()
	if rc == nil {
		t.Fatal("expected fallback root cause")
	}
	if rc.Object.Name != "ks" {
		t.Errorf("expected timeline fallback to ks, got %s", rc.Object.Name)
	}
}

func TestRootCause_NilWhenHealthy(t *testing.T) {
	s := Snapshot{Nodes: []Node{
		{Ref: ObjectRef{Name: "ks"}, Conditions: []metav1.Condition{
			cond("Ready", metav1.ConditionTrue, "Applied", "", time.Now()),
		}},
	}}
	if s.RootCause() != nil {
		t.Error("expected nil for healthy snapshot")
	}
}

func TestRootCause_NilWhenEmpty(t *testing.T) {
	if (Snapshot{}).RootCause() != nil {
		t.Error("expected nil for empty snapshot")
	}
}

func TestRootCause_LeafIsHealthy(t *testing.T) {
	ksRef := ObjectRef{Name: "ks", Kind: "Kustomization"}
	grRef := ObjectRef{Name: "gr", Kind: "GitRepository"}

	s := Snapshot{
		Nodes: []Node{
			{Ref: ksRef, Conditions: []metav1.Condition{failedCond("DependencyNotReady", "", time.Now())}},
			{Ref: grRef, Conditions: []metav1.Condition{
				cond("Ready", metav1.ConditionTrue, "Succeeded", "", time.Now()),
			}},
		},
		Edges: []Edge{{From: ksRef, To: grRef, Type: "sourceRef"}},
	}

	if s.RootCause() != nil {
		t.Error("expected nil when leaf is healthy")
	}
}

func TestBuild_SingleNode(t *testing.T) {
	scheme := newScheme(t)
	gr := failedGR("src", "flux-system")
	ks := makeKS("app", "flux-system", "GitRepository", "src", nil, []metav1.Condition{
		failedCond("ArtifactFailed", "source not found", time.Now()),
	})

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(gr).Build()

	snap, err := Build(context.Background(), c, ks)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(snap.Nodes) != 2 {
		t.Errorf("expected 2 nodes, got %d", len(snap.Nodes))
	}
	if len(snap.Edges) != 1 {
		t.Errorf("expected 1 edge, got %d", len(snap.Edges))
	}
	if snap.Trigger.Name != "app" {
		t.Errorf("expected trigger=app, got %s", snap.Trigger.Name)
	}
	rc := snap.RootCause()
	if rc == nil || rc.Object.Name != "src" {
		t.Errorf("expected root cause src, got %v", rc)
	}
}

func TestBuild_WithDependsOn(t *testing.T) {
	scheme := newScheme(t)
	gr := failedGR("src", "flux-system")
	base := makeKS("base", "flux-system", "GitRepository", "src", nil, []metav1.Condition{
		failedCond("ArtifactFailed", "source not found", time.Now()),
	})
	app := makeKS("app", "flux-system", "GitRepository", "src",
		[]kustomizev1.DependencyReference{{Name: "base"}},
		[]metav1.Condition{failedCond("DependencyNotReady", "base not ready", time.Now())},
	)

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(gr, base).Build()

	snap, err := Build(context.Background(), c, app)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(snap.Nodes) != 3 {
		t.Errorf("expected 3 nodes, got %d", len(snap.Nodes))
	}
	rc := snap.RootCause()
	if rc == nil || rc.Object.Name != "src" {
		t.Errorf("expected root cause src, got %v", rc)
	}
}

func TestBuild_VisitedMapDedup(t *testing.T) {
	scheme := newScheme(t)
	gr := failedGR("src", "flux-system")

	dep1 := makeKS("dep1", "flux-system", "GitRepository", "src", nil, nil)
	dep2 := makeKS("dep2", "flux-system", "GitRepository", "src", nil, nil)
	app := makeKS("app", "flux-system", "GitRepository", "src",
		[]kustomizev1.DependencyReference{{Name: "dep1"}, {Name: "dep2"}},
		[]metav1.Condition{failedCond("DependencyNotReady", "", time.Now())},
	)

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(gr, dep1, dep2).Build()

	snap, err := Build(context.Background(), c, app)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	srcCount := 0
	for _, n := range snap.Nodes {
		if n.Ref.Name == "src" {
			srcCount++
		}
	}
	if srcCount != 1 {
		t.Errorf("expected src to appear once, got %d", srcCount)
	}
}

func TestBuild_SourceWithNamespace(t *testing.T) {
	scheme := newScheme(t)

	gr := sourceObj("GitRepository", "src", "infra", []interface{}{
		map[string]interface{}{
			"type":               "Ready",
			"status":             "False",
			"reason":             "GitOperationFailed",
			"message":            "auth",
			"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
		},
	})

	ks := &kustomizev1.Kustomization{
		ObjectMeta: metav1.ObjectMeta{Name: "app", Namespace: "flux-system", Generation: 1},
		Spec: kustomizev1.KustomizationSpec{
			SourceRef: kustomizev1.CrossNamespaceSourceReference{
				Kind:      "GitRepository",
				Name:      "src",
				Namespace: "infra",
			},
		},
	}

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(gr).Build()

	snap, err := Build(context.Background(), c, ks)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	var found bool
	for _, n := range snap.Nodes {
		if n.Ref.Name == "src" && n.Ref.Namespace == "infra" {
			found = true
		}
	}
	if !found {
		t.Error("expected source node with namespace=infra")
	}
}

func TestBuild_GVKFields(t *testing.T) {
	scheme := newScheme(t)
	gr := failedGR("src", "flux-system")
	ks := makeKS("app", "flux-system", "GitRepository", "src", nil, nil)

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(gr).Build()

	snap, err := Build(context.Background(), c, ks)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	if snap.Trigger.Kind != kustomizev1.KustomizationKind {
		t.Errorf("trigger kind=%s", snap.Trigger.Kind)
	}
	if snap.Trigger.Group != kustomizev1.GroupVersion.Group {
		t.Errorf("trigger group=%s", snap.Trigger.Group)
	}

	var srcNode *Node
	for i := range snap.Nodes {
		if snap.Nodes[i].Ref.Kind == "GitRepository" {
			srcNode = &snap.Nodes[i]
		}
	}
	if srcNode == nil {
		t.Fatal("no GitRepository node in snapshot")
	}
	if srcNode.Ref.Group != "source.toolkit.fluxcd.io" {
		t.Errorf("source group=%s", srcNode.Ref.Group)
	}
}

func TestBuild_EdgeTypesPresent(t *testing.T) {
	scheme := newScheme(t)
	gr := failedGR("src", "flux-system")
	base := makeKS("base", "flux-system", "GitRepository", "src", nil, nil)
	app := makeKS("app", "flux-system", "GitRepository", "src",
		[]kustomizev1.DependencyReference{{Name: "base"}}, nil)

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(gr, base).Build()

	snap, err := Build(context.Background(), c, app)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	types := map[string]bool{}
	for _, e := range snap.Edges {
		types[e.Type] = true
	}
	if !types["dependsOn"] {
		t.Error("expected a dependsOn edge")
	}
	if !types["sourceRef"] {
		t.Error("expected a sourceRef edge")
	}
}

func TestBuild_SchemaGroupVersionKind(t *testing.T) {
	scheme := newScheme(t)
	gr := failedGR("src", "flux-system")
	ks := makeKS("app", "flux-system", "GitRepository", "src", nil, nil)

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(gr).Build()

	snap, err := Build(context.Background(), c, ks)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	if snap.CapturedAt.IsZero() {
		t.Error("CapturedAt must be set")
	}
}
