// Package main is the entry point for the flux-snapshot-controller, which watches Kustomizations and emits structured failure snapshots.
package main

import (
	"os"

	kustomizev1 "github.com/fluxcd/kustomize-controller/api/v1"
	"github.com/lukaross368/flux-snapshot/internal/controller"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager/signals"
)

var log = logf.Log.WithName("flux-snapshot-controller")

func main() {
	ctrl.SetLogger(zap.New())

	scheme := runtime.NewScheme()

	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		log.Error(err, "unable to add client-go types to scheme")
		os.Exit(1)
	}

	if err := kustomizev1.AddToScheme(scheme); err != nil {
		log.Error(err, "unable to add Kustomize types to scheme")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme: scheme,
	})
	if err != nil {
		log.Error(err, "unable to create manager")
		os.Exit(1)
	}

	if err := ctrl.NewControllerManagedBy(mgr).
		For(&kustomizev1.Kustomization{}).
		Complete(controller.NewSnapshotReconciler(mgr.GetClient())); err != nil {
		log.Error(err, "unable to create controller", "controller", "Snapshot")
		os.Exit(1)
	}

	if err := mgr.Start(signals.SetupSignalHandler()); err != nil {
		log.Error(err, "unable to start manager")
		os.Exit(1)
	}

}
