package notification

import (
	"testing"
	"time"

	"github.com/go-logr/logr"
	"github.com/lukaross368/flux-snapshot/internal/snapshot"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var (
	ksRef = snapshot.ObjectRef{Name: "app", Kind: "Kustomization", Namespace: "flux-system", Group: "kustomize.toolkit.fluxcd.io"}
	grRef = snapshot.ObjectRef{Name: "src", Kind: "GitRepository", Namespace: "flux-system", Group: "source.toolkit.fluxcd.io"}
)

func failedCond(reason, msg string) metav1.Condition {
	return metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionFalse,
		Reason:             reason,
		Message:            msg,
		LastTransitionTime: metav1.NewTime(time.Now().Add(-time.Minute)),
	}
}

func fullSnap() snapshot.Snapshot {
	edge := snapshot.Edge{From: ksRef, To: grRef, Type: "sourceRef"}
	ksCond := failedCond("ArtifactFailed", "source not found")
	grCond := failedCond("GitOperationFailed", "auth failed")

	nodes := []snapshot.Node{
		{Ref: ksRef, Conditions: []metav1.Condition{ksCond},
			ObservedGeneration: -1, DesiredGeneration: 1},
		{
			Ref:        grRef,
			Conditions: []metav1.Condition{grCond},
			Events: []snapshot.Event{
				{Type: "Warning", Reason: "GitOperationFailed", Message: "auth failed", Count: 5, LastTime: time.Now()},
				{Type: "Normal", Reason: "Info", Message: "reconciling", Count: 1, LastTime: time.Now()},
			},
			ObservedGeneration: -1,
			DesiredGeneration:  1,
		},
	}

	return snapshot.Snapshot{
		Trigger:  ksRef,
		Nodes:    nodes,
		Edges:    []snapshot.Edge{edge},
		Timeline: []snapshot.ConditionTransition{{Time: time.Now().Add(-time.Minute), Object: grRef, Condition: grCond}},
	}
}

func TestNotify_EmptySnapshot(_ *testing.T) {
	Notify(logr.Discard(), snapshot.Snapshot{})
}

func TestNotify_Full(_ *testing.T) {
	Notify(logr.Discard(), fullSnap())
}

func TestLogRootCause_NilRootCause(_ *testing.T) {
	s := snapshot.Snapshot{
		Nodes: []snapshot.Node{{
			Ref: ksRef,
			Conditions: []metav1.Condition{{
				Type: "Ready", Status: metav1.ConditionTrue,
				Reason: "Applied", LastTransitionTime: metav1.Now(),
			}},
		}},
	}
	logRootCause(logr.Discard(), s)
}

func TestLogCascade_SingleNode(_ *testing.T) {
	s := snapshot.Snapshot{
		Nodes: []snapshot.Node{{
			Ref:                ksRef,
			ObservedGeneration: 2,
			DesiredGeneration:  2,
		}},
	}
	logCascade(logr.Discard(), s)
}

func TestLogCascade_GenerationDrift(_ *testing.T) {
	s := snapshot.Snapshot{
		Nodes: []snapshot.Node{{
			Ref:                ksRef,
			ObservedGeneration: -1,
			DesiredGeneration:  1,
		}},
	}
	logCascade(logr.Discard(), s)
}

func TestLogWarningEvents_OnlyWarnings(_ *testing.T) {
	s := snapshot.Snapshot{
		Nodes: []snapshot.Node{{
			Ref: grRef,
			Events: []snapshot.Event{
				{Type: "Warning", Reason: "GitOperationFailed", Count: 3, LastTime: time.Now()},
				{Type: "Normal", Reason: "Info", Count: 1, LastTime: time.Now()},
			},
		}},
	}
	logWarningEvents(logr.Discard(), s)
}

func TestLogWarningEvents_NoEvents(_ *testing.T) {
	s := snapshot.Snapshot{
		Nodes: []snapshot.Node{{Ref: grRef}},
	}
	logWarningEvents(logr.Discard(), s)
}
