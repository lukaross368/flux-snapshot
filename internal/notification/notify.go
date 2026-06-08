// Package notification logs structured failure snapshots to the controller logger.
package notification

import (
	"time"

	"github.com/go-logr/logr"
	"github.com/lukaross368/flux-snapshot/internal/snapshot"
)

// Notify logs root cause, cascade chain, and warning events for a failure snapshot.
func Notify(log logr.Logger, snap snapshot.Snapshot) {
	logRootCause(log, snap)
	logCascade(log, snap)
	logWarningEvents(log, snap)
}

type rootCauseDetails struct {
	Trigger  string `json:"trigger"`
	Object   string `json:"object"`
	Kind     string `json:"kind"`
	Group    string `json:"group"`
	Reason   string `json:"reason"`
	Message  string `json:"message"`
	Since    string `json:"since"`
	Duration string `json:"duration"`
}

func logRootCause(log logr.Logger, snap snapshot.Snapshot) {
	rc := snap.RootCause()
	if rc == nil {
		return
	}
	log.Info("root cause", "details", rootCauseDetails{
		Trigger:  snap.Trigger.Name,
		Object:   rc.Object.Name,
		Kind:     rc.Object.Kind,
		Group:    rc.Object.Group,
		Reason:   rc.Condition.Reason,
		Message:  rc.Condition.Message,
		Since:    rc.Time.Format(time.RFC3339),
		Duration: time.Since(rc.Time).Round(time.Second).String(),
	})
}

func logCascade(log logr.Logger, snap snapshot.Snapshot) {
	type nodeStatus struct {
		Name               string `json:"name"`
		Kind               string `json:"kind"`
		ObservedGeneration int64  `json:"observedGeneration"`
		DesiredGeneration  int64  `json:"desiredGeneration"`
		GenerationDrift    bool   `json:"generationDrift"`
	}
	statuses := make([]nodeStatus, len(snap.Nodes))
	for i, n := range snap.Nodes {
		statuses[i] = nodeStatus{
			Name:               n.Ref.Name,
			Kind:               n.Ref.Kind,
			ObservedGeneration: n.ObservedGeneration,
			DesiredGeneration:  n.DesiredGeneration,
			GenerationDrift:    n.ObservedGeneration != n.DesiredGeneration,
		}
	}
	log.Info("affected chain", "chain", snap.ChainSummary(), "nodes", statuses)
}

func logWarningEvents(log logr.Logger, snap snapshot.Snapshot) {
	for _, node := range snap.Nodes {
		for _, e := range node.Events {
			if e.Type != "Warning" {
				continue
			}
			log.Info("warning event",
				"object", node.Ref.Name,
				"kind", node.Ref.Kind,
				"reason", e.Reason,
				"message", e.Message,
				"count", e.Count,
				"lastSeen", e.LastTime.Format(time.RFC3339),
			)
		}
	}
}
