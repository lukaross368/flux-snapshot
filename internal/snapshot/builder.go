// Package snapshot builds a point-in-time record of a Flux dependency chain.
package snapshot

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	kustomizev1 "github.com/fluxcd/kustomize-controller/api/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// ObjectRef identifies a single Kubernetes object.
type ObjectRef struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Kind      string `json:"kind"`
	Group     string `json:"group"`
}

// Snapshot is a point-in-time record of a Flux dependency chain at the moment of failure.
type Snapshot struct {
	Trigger    ObjectRef             `json:"trigger"`
	CapturedAt time.Time             `json:"capturedAt"`
	TraceID    string                `json:"traceId,omitempty"`
	Nodes      []Node                `json:"nodes"`
	Edges      []Edge                `json:"edges"`
	Timeline   []ConditionTransition `json:"timeline"`
}

// ConditionTransition is one entry in the cross-chain timeline.
type ConditionTransition struct {
	Time      time.Time        `json:"time"`
	Object    ObjectRef        `json:"object"`
	Condition metav1.Condition `json:"condition"`
}

// Node holds the observed state of one object in the dependency chain.
type Node struct {
	Ref                ObjectRef          `json:"ref"`
	Conditions         []metav1.Condition `json:"conditions"`
	ObservedGeneration int64              `json:"observedGeneration"`
	DesiredGeneration  int64              `json:"desiredGeneration"`
	SourceRevision     string             `json:"sourceRevision,omitempty"`
	Events             []Event            `json:"events,omitempty"`
}

// Event is a Kubernetes event attached to an object in the dependency chain.
type Event struct {
	Reason    string    `json:"reason"`
	Message   string    `json:"message"`
	Type      string    `json:"type"`
	Count     int32     `json:"count"`
	FirstTime time.Time `json:"firstTimestamp"`
	LastTime  time.Time `json:"lastTimestamp"`
}

// Edge is a directed relationship between two nodes.
type Edge struct {
	From ObjectRef `json:"from"`
	To   ObjectRef `json:"to"`
	Type string    `json:"type"` // "dependsOn" | "sourceRef"
}

func listEventsByNamespace(ctx context.Context, c client.Client, ns string) ([]unstructured.Unstructured, error) {
	eventList := &unstructured.UnstructuredList{}
	eventList.SetGroupVersionKind(schema.GroupVersionKind{Group: "", Version: "v1", Kind: "EventList"})
	if err := c.List(ctx, eventList, client.InNamespace(ns)); err != nil {
		return nil, err
	}
	return eventList.Items, nil
}

// Build constructs a Snapshot by walking the Kustomization dependency graph.
func Build(ctx context.Context, c client.Client, ks *kustomizev1.Kustomization) (Snapshot, error) {
	ref := ksRef(ks)
	visited := map[string]bool{objectKey(ref): true}

	nodes, edges, err := buildDependencyGraph(ctx, c, ks, []Node{ksNode(ks)}, visited)
	if err != nil {
		return Snapshot{}, err
	}
	if edges == nil {
		edges = []Edge{}
	}

	nsByEvents := map[string][]unstructured.Unstructured{}
	for i := range nodes {
		ns := nodes[i].Ref.Namespace
		if _, fetched := nsByEvents[ns]; !fetched {
			raw, err := listEventsByNamespace(ctx, c, ns)
			if err != nil {
				return Snapshot{}, err
			}
			nsByEvents[ns] = raw
		}
		for _, item := range nsByEvents[ns] {
			name, _, _ := unstructured.NestedString(item.Object, "involvedObject", "name")
			if name != nodes[i].Ref.Name {
				continue
			}
			var event Event
			if err := runtime.DefaultUnstructuredConverter.FromUnstructured(item.Object, &event); err == nil {
				nodes[i].Events = append(nodes[i].Events, event)
			}
		}
	}

	return Snapshot{
		Trigger:    ref,
		CapturedAt: time.Now(),
		TraceID:    ks.Annotations["reconciler.fluxcd.io/trace"],
		Nodes:      nodes,
		Edges:      edges,
		Timeline:   buildTimeline(nodes),
	}, nil
}

func buildDependencyGraph(ctx context.Context, c client.Client, ks *kustomizev1.Kustomization, nodes []Node, visited map[string]bool) ([]Node, []Edge, error) {
	var edges []Edge

	for _, dep := range ks.Spec.DependsOn {
		ns := dep.Namespace
		if ns == "" {
			ns = ks.Namespace
		}
		var depKS kustomizev1.Kustomization
		if err := c.Get(ctx, client.ObjectKey{Namespace: ns, Name: dep.Name}, &depKS); err != nil {
			return nil, nil, err
		}
		depNode := ksNode(&depKS)
		if key := objectKey(depNode.Ref); !visited[key] {
			visited[key] = true
			nodes = append(nodes, depNode)
		}
		edges = append(edges, Edge{From: ksRef(ks), To: ksRef(&depKS), Type: "dependsOn"})

		var newEdges []Edge
		var err error
		nodes, newEdges, err = buildDependencyGraph(ctx, c, &depKS, nodes, visited)
		if err != nil {
			return nil, nil, err
		}
		edges = append(edges, newEdges...)
	}

	srcRef, srcNode, err := fetchSourceNode(ctx, c, ks)
	if err != nil {
		return nil, nil, err
	}
	if key := objectKey(srcRef); !visited[key] {
		visited[key] = true
		nodes = append(nodes, srcNode)
	}
	edges = append(edges, Edge{From: ksRef(ks), To: srcRef, Type: "sourceRef"})

	return nodes, edges, nil
}

func fetchSourceNode(ctx context.Context, c client.Client, ks *kustomizev1.Kustomization) (ObjectRef, Node, error) {
	sr := ks.Spec.SourceRef
	ns := sr.Namespace
	if ns == "" {
		ns = ks.Namespace
	}

	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(schema.GroupVersionKind{Group: "source.toolkit.fluxcd.io", Version: "v1", Kind: sr.Kind})
	if err := c.Get(ctx, client.ObjectKey{Namespace: ns, Name: sr.Name}, obj); err != nil {
		return ObjectRef{}, Node{}, err
	}

	ref := ObjectRef{Name: sr.Name, Namespace: ns, Kind: sr.Kind, Group: "source.toolkit.fluxcd.io"}

	var conditions []metav1.Condition
	rawConditions, found, _ := unstructured.NestedSlice(obj.Object, "status", "conditions")
	if found {
		for _, raw := range rawConditions {
			if condMap, ok := raw.(map[string]interface{}); ok {
				var cond metav1.Condition
				if err := runtime.DefaultUnstructuredConverter.FromUnstructured(condMap, &cond); err == nil {
					conditions = append(conditions, cond)
				}
			}
		}
	}
	observedGen, _, _ := unstructured.NestedInt64(obj.Object, "status", "observedGeneration")

	return ref, Node{
		Ref:                ref,
		Conditions:         conditions,
		ObservedGeneration: observedGen,
		DesiredGeneration:  obj.GetGeneration(),
	}, nil
}

func buildTimeline(nodes []Node) []ConditionTransition {
	var transitions []ConditionTransition
	for _, n := range nodes {
		for _, c := range n.Conditions {
			transitions = append(transitions, ConditionTransition{
				Time:      c.LastTransitionTime.Time,
				Object:    n.Ref,
				Condition: c,
			})
		}
	}
	sort.Slice(transitions, func(i, j int) bool {
		return transitions[i].Time.Before(transitions[j].Time)
	})
	return transitions
}

func ksRef(ks *kustomizev1.Kustomization) ObjectRef {
	return ObjectRef{
		Name:      ks.Name,
		Namespace: ks.Namespace,
		Kind:      kustomizev1.KustomizationKind,
		Group:     kustomizev1.GroupVersion.Group,
	}
}

func ksNode(ks *kustomizev1.Kustomization) Node {
	return Node{
		Ref:                ksRef(ks),
		Conditions:         ks.Status.Conditions,
		ObservedGeneration: ks.Status.ObservedGeneration,
		DesiredGeneration:  ks.Generation,
		SourceRevision:     ks.Status.LastAppliedRevision,
	}
}

// RootCause returns the leaf node whose Ready condition is False.
// Leaf node (no outgoing edges) is the true failure origin; downstream objects show cascade symptoms.
func (s Snapshot) RootCause() *ConditionTransition {
	hasOutgoing := map[string]bool{}
	for _, e := range s.Edges {
		hasOutgoing[objectKey(e.From)] = true
	}
	for _, n := range s.Nodes {
		if hasOutgoing[objectKey(n.Ref)] {
			continue
		}
		for _, c := range n.Conditions {
			if c.Type == "Ready" && c.Status == metav1.ConditionFalse {
				return &ConditionTransition{Time: c.LastTransitionTime.Time, Object: n.Ref, Condition: c}
			}
		}
	}
	for _, t := range s.Timeline {
		if t.Condition.Type == "Ready" && t.Condition.Status == metav1.ConditionFalse {
			return &t
		}
	}
	return nil
}

// ChainSummary returns a human-readable representation of the dependency chain.
func (s Snapshot) ChainSummary() string {
	names := make([]string, len(s.Nodes))
	for i, n := range s.Nodes {
		names[i] = fmt.Sprintf("%s(%s)", n.Ref.Name, n.Ref.Kind)
	}
	return strings.Join(names, " → ")
}

func objectKey(ref ObjectRef) string {
	return ref.Group + "/" + ref.Kind + "/" + ref.Namespace + "/" + ref.Name
}
