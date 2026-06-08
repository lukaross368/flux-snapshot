// Package controller contains the SnapshotReconciler which watches Kustomizations and emits structured failure snapshots.
package controller

import (
	"context"
	"testing"
	"time"

	kustomizev1 "github.com/fluxcd/kustomize-controller/api/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
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

func failingKS(name, ns, sourceKind, sourceName string) *kustomizev1.Kustomization {
	return &kustomizev1.Kustomization{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Generation: 1},
		Spec: kustomizev1.KustomizationSpec{
			SourceRef: kustomizev1.CrossNamespaceSourceReference{Kind: sourceKind, Name: sourceName},
		},
		Status: kustomizev1.KustomizationStatus{
			Conditions: []metav1.Condition{{
				Type:               "Ready",
				Status:             metav1.ConditionFalse,
				Reason:             "ArtifactFailed",
				Message:            "source not found",
				LastTransitionTime: metav1.Now(),
			}},
			ObservedGeneration: 1,
		},
	}
}

func readyKS(name, ns string) *kustomizev1.Kustomization {
	return &kustomizev1.Kustomization{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Generation: 1},
		Spec: kustomizev1.KustomizationSpec{
			SourceRef: kustomizev1.CrossNamespaceSourceReference{Kind: "GitRepository", Name: "src"},
		},
		Status: kustomizev1.KustomizationStatus{
			Conditions: []metav1.Condition{{
				Type:               "Ready",
				Status:             metav1.ConditionTrue,
				Reason:             "Applied",
				LastTransitionTime: metav1.Now(),
			}},
			ObservedGeneration: 1,
		},
	}
}

func failedGR(name, ns string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "source.toolkit.fluxcd.io/v1",
		"kind":       "GitRepository",
		"metadata":   map[string]interface{}{"name": name, "namespace": ns, "generation": int64(1)},
		"status": map[string]interface{}{
			"observedGeneration": int64(1),
			"conditions": []interface{}{map[string]interface{}{
				"type":               "Ready",
				"status":             "False",
				"reason":             "GitOperationFailed",
				"message":            "auth failed",
				"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
			}},
		},
	}}
}

func req(name, ns string) ctrl.Request {
	return ctrl.Request{NamespacedName: types.NamespacedName{Name: name, Namespace: ns}}
}

func TestNewSnapshotReconciler(t *testing.T) {
	scheme := newScheme(t)
	c := fake.NewClientBuilder().WithScheme(scheme).Build()
	r := NewSnapshotReconciler(c)
	if r == nil {
		t.Fatal("expected non-nil reconciler")
	}
	if r.lastNotified == nil {
		t.Fatal("lastNotified map must be initialised")
	}
}

func TestReconcile_FailingKS_NotifiesOnce(t *testing.T) {
	scheme := newScheme(t)
	ks := failingKS("app", "flux-system", "GitRepository", "src")
	gr := failedGR("src", "flux-system")
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ks, gr).Build()

	r := NewSnapshotReconciler(c)

	res, err := r.Reconcile(context.Background(), req("app", "flux-system"))
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if (res != ctrl.Result{}) {
		t.Errorf("unexpected non-zero result: %v", res)
	}

	r.mu.Lock()
	n := len(r.lastNotified)
	r.mu.Unlock()
	if n == 0 {
		t.Error("expected dedup entry after first reconcile")
	}

	_, err = r.Reconcile(context.Background(), req("app", "flux-system"))
	if err != nil {
		t.Fatalf("second Reconcile: %v", err)
	}
}

func TestReconcile_ReadyKS_NoNotification(t *testing.T) {
	scheme := newScheme(t)
	ks := readyKS("app", "flux-system")
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ks).Build()

	r := NewSnapshotReconciler(c)
	_, err := r.Reconcile(context.Background(), req("app", "flux-system"))
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}

	r.mu.Lock()
	n := len(r.lastNotified)
	r.mu.Unlock()
	if n != 0 {
		t.Errorf("expected no dedup entries for ready KS, got %d", n)
	}
}

func TestReconcile_NotFound(t *testing.T) {
	scheme := newScheme(t)
	c := fake.NewClientBuilder().WithScheme(scheme).Build()

	r := NewSnapshotReconciler(c)
	_, err := r.Reconcile(context.Background(), req("does-not-exist", "flux-system"))
	if err != nil {
		t.Fatalf("expected nil error for not-found, got %v", err)
	}
}

func TestReconcile_DedupWindowExpiry(t *testing.T) {
	scheme := newScheme(t)
	ks := failingKS("app", "flux-system", "GitRepository", "src")
	gr := failedGR("src", "flux-system")
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ks, gr).Build()

	r := NewSnapshotReconciler(c)

	// Manually backdate the dedup entry beyond the window.
	_, err := r.Reconcile(context.Background(), req("app", "flux-system"))
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}

	r.mu.Lock()
	for k := range r.lastNotified {
		r.lastNotified[k] = time.Now().Add(-(dedupeWindow + time.Second))
	}
	r.mu.Unlock()

	before := len(r.lastNotified)
	_, err = r.Reconcile(context.Background(), req("app", "flux-system"))
	if err != nil {
		t.Fatalf("Reconcile after window expiry: %v", err)
	}

	r.mu.Lock()
	after := len(r.lastNotified)
	r.mu.Unlock()
	if after != before {
		t.Errorf("expected same number of dedup entries, got before=%d after=%d", before, after)
	}
}
