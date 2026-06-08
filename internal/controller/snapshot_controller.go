package controller

import (
	"context"
	"fmt"
	"sync"
	"time"

	kustomizev1 "github.com/fluxcd/kustomize-controller/api/v1"
	fluxmeta "github.com/fluxcd/pkg/apis/meta"
	"github.com/lukaross368/flux-snapshot/internal/notification"
	"github.com/lukaross368/flux-snapshot/internal/snapshot"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
)

const dedupeWindow = 5 * time.Minute

var log = logf.Log.WithName("flux-snapshot-controller")

// SnapshotReconciler watches Kustomizations and emits structured failure snapshots.
type SnapshotReconciler struct {
	client.Client
	mu           sync.Mutex
	lastNotified map[string]time.Time
}

// NewSnapshotReconciler constructs a SnapshotReconciler with an initialised dedup map.
func NewSnapshotReconciler(c client.Client) *SnapshotReconciler {
	return &SnapshotReconciler{
		Client:       c,
		lastNotified: make(map[string]time.Time),
	}
}

// Reconcile processes a Kustomization event and notifies on new root-cause failures.
func (r *SnapshotReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := log.WithValues("kustomization", req.NamespacedName)

	var ks kustomizev1.Kustomization
	if err := r.Get(ctx, req.NamespacedName, &ks); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	for _, condition := range ks.Status.Conditions {
		if condition.Type == fluxmeta.ReadyCondition && condition.Status == metav1.ConditionFalse {
			snap, err := snapshot.Build(ctx, r.Client, &ks)
			if err != nil {
				log.Error(err, "failed to build snapshot")
				return ctrl.Result{}, err
			}
			rc := snap.RootCause()
			if rc == nil {
				break
			}
			rcKey := fmt.Sprintf("%s/%s/%s/%s", rc.Object.Group, rc.Object.Kind, rc.Object.Namespace, rc.Object.Name)
			r.mu.Lock()
			last, seen := r.lastNotified[rcKey]
			shouldNotify := !seen || time.Since(last) > dedupeWindow
			if shouldNotify {
				r.lastNotified[rcKey] = time.Now()
			}
			r.mu.Unlock()
			if shouldNotify {
				notification.Notify(log, snap)
			}
			break
		}
	}

	return ctrl.Result{}, nil
}
