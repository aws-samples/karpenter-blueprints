# Karpenter Blueprint: Balanced Consolidation Policy

## Purpose

Karpenter's `consolidationPolicy` decides which nodes are candidates for consolidation. The default `WhenEmptyOrUnderutilized` is aggressive — any node that could be removed or replaced to reduce cost is fair game — which produces two behaviors customers commonly hit:

- **Marginal replaces.** A node running a couple of pods that could technically fit on a same-or-similar-family instance gets replaced. Savings are near zero; several pods get evicted for no real benefit.
- **Consolidation timing pressure.** To contain this, customers reach for scheduled `disruption.budgets` with `nodes: 0` windows during business hours, pausing consolidation until off-hours. That controls the *when* but not the *what* — off-hours consolidation still churns marginal moves.

The `Balanced` policy (Karpenter v1.14+) addresses the *what*: it **scores every consolidation action** and only proceeds when the estimated savings outweigh the pod disruption. Because it filters out the marginal actions that made scheduled budgets attractive, teams can be less restrictive with their budget windows once Balanced is in play.

The score is a ratio computed per action:

```
score = savings_fraction / disruption_fraction

  savings_fraction    = savings / nodepool_total_cost
  disruption_fraction = disruption_cost / nodepool_total_disruption_cost
```

An action is approved when `score >= 1/k`. Balanced uses `k = 2`, so the effective **approval threshold is 0.5** — the savings must cover at least half the disruption in fractional terms. Both sides are dimensionless, so the threshold is scale-invariant across cluster sizes. Two levers change per-pod disruption weight in the numerator:

- **Pod priority.** Higher-priority pods count as more disruptive, making their host less consolidation-worthy.
- **`karpenter.sh/disruption-cost` annotation.** Per-pod override on disruption weight. Since Karpenter v1.15, this replaces `controller.kubernetes.io/pod-deletion-cost` for steering consolidation. Karpenter still falls back to the old annotation when the new one is absent, but that fallback is deprecated (see the [v1.15 upgrade guide](https://karpenter.sh/docs/upgrading/upgrade-guide/)).

Reference: [Karpenter Balanced consolidation docs](https://karpenter.sh/docs/concepts/disruption/#balanced-consolidation) and the [design RFC](https://github.com/kubernetes-sigs/karpenter/blob/main/designs/balanced-consolidation.md) (see "Why k=2" for the choice of threshold).

## Requirements

- An EKS cluster running self-managed Karpenter **v1.14 or later**. The repo's `cluster/terraform/` template installs a compatible version.
- The cluster's default `EC2NodeClass` exists. The repo's cluster template creates one named `default`, and this blueprint references it.

> **EKS Auto Mode is not currently supported.** Auto Mode ships a bundled Karpenter build that is behind OSS v1.14, so the `NodePool` CRD in Auto Mode does not yet list `Balanced` as a valid `consolidationPolicy`. Applying this blueprint on Auto Mode fails with `Unsupported value: "Balanced": supported values: "WhenEmpty", "WhenEmptyOrUnderutilized"`. Once Auto Mode's Karpenter reaches v1.14+, the same NodePool works on Auto Mode by swapping `nodeClassRef.group` to `eks.amazonaws.com`.

## Deploy

```sh
kubectl apply -f balanced-consolidation.yaml
```

This creates a NodePool named `balanced-consolidation` that references the cluster's `default` `EC2NodeClass`. No separate NodeClass is created — the blueprint adds only what's specific to it (a NodePool + workloads), leaving `default` free for other blueprints or workloads.

The NodePool pins to on-demand, generation-3+, and excludes small instance sizes (`nano`/`micro`/`small`/`medium`/`large`) so instance-type transitions during consolidation are visible in `kubectl get nodes`. Categories are limited to `c/m/r`.

Apply the sample workload — three deployments (baseline, low-priority, high-priority) and two PriorityClasses:

```sh
kubectl apply -f workload.yaml
```

All deployments start at `replicas: 0` and set `nodeSelector: blueprint=balanced-consolidation` so they land only on this blueprint's NodePool.

## Walkthrough

The rest of this document runs the **same scale sequence twice** — once under `WhenEmptyOrUnderutilized`, once under `Balanced` — and observes what Karpenter does at each step. The sequence is designed so that instance-type changes are visible: watch `kubectl get nodes` between steps.

Start the NodePool on `WhenEmptyOrUnderutilized` so we have a baseline:

```sh
kubectl patch nodepool balanced-consolidation --type=merge \
  -p '{"spec":{"disruption":{"consolidationPolicy":"WhenEmptyOrUnderutilized"}}}'
```

Open a second terminal to watch node changes:

```sh
kubectl get nodes -l karpenter.sh/nodepool=balanced-consolidation \
  -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type -w
```

### Step 1 — Scale up: `0 → 5`

```sh
kubectl scale deployment balanced-inflate --replicas=5
```

Each pod requests `1` vCPU and `1Gi` memory, so 5 pods need ~5 vCPU. Karpenter provisions a single instance that fits — under the `c/m/r` filter with small sizes excluded, the cheapest option that holds 5 vCPU worth of pods is a `2xlarge` (8 vCPU).

**Expected** (from a real run on us-west-2):

```
NAME                                       STATUS   INSTANCE-TYPE   CAPACITY-TYPE
ip-10-1-7-254.us-west-2.compute.internal   Ready    c6a.2xlarge     on-demand
```

Karpenter emits a chain of NodeClaim events you can follow — `Nominated → Launched → Registered → Initialized → Ready`:

```sh
kubectl describe nodeclaim -l karpenter.sh/nodepool=balanced-consolidation | grep -A20 Events
```

### Step 2 — Scale up further: `5 → 10`

```sh
kubectl scale deployment balanced-inflate --replicas=10
```

Now 10 vCPU worth of pods. The existing `2xlarge` (8 vCPU) can't hold them all, so Karpenter **adds a second node** rather than replacing the existing one.

**Expected**:

```
NAME                                        STATUS   INSTANCE-TYPE
ip-10-1-29-19.us-west-2.compute.internal    Ready    c6a.xlarge     <- new
ip-10-1-7-254.us-west-2.compute.internal    Ready    c6a.2xlarge
```

Pod placement should show 7 pods on the `2xlarge` and 3 on the new `xlarge`:

```sh
kubectl get pods -l app=balanced-inflate -o wide \
  | awk 'NR>1 {print $7}' | sort | uniq -c
```

### Step 3 — Scale down under `WhenEmptyOrUnderutilized`: `10 → 3`

```sh
kubectl scale deployment balanced-inflate --replicas=3
```

Under `WhenEmptyOrUnderutilized`, Karpenter sees the `2xlarge` is now oversized for the remaining pods. It launches a new `xlarge`, drains pods onto it (and the existing `xlarge`), then removes the empty `2xlarge`. **The replace happens automatically** — no human action needed.

Wait about 2 minutes and watch:

```sh
kubectl get nodes -l karpenter.sh/nodepool=balanced-consolidation -L node.kubernetes.io/instance-type
```

**Expected** (both nodes are now `xlarge`; the `2xlarge` is gone):

```
NAME                                        STATUS   INSTANCE-TYPE
ip-10-1-24-42.us-west-2.compute.internal    Ready    c6a.xlarge     <- new, from the replace
ip-10-1-29-19.us-west-2.compute.internal    Ready    c6a.xlarge
```

Trace what happened via the disruption events:

```sh
kubectl get events --sort-by=.lastTimestamp \
  | grep -iE "disrupting|nominated|launched|registered|ready.*NodeClaim"
```

You'll see the new NodeClaim come up (`Launched → Ready`) and then the old `2xlarge` NodeClaim emit `DisruptionTerminating: Disrupting NodeClaim: Empty` once its pods drained onto the new capacity.

### Step 4 — Scale to zero: `3 → 0`

```sh
kubectl scale deployment balanced-inflate --replicas=0
```

Both nodes become empty. Empty-node consolidation is a fast path in Karpenter and fires under any `consolidationPolicy` (including `Balanced`). After ~60 seconds:

**Expected**:

```
No resources found  # no nodes tagged with karpenter.sh/nodepool=balanced-consolidation
```

Events:

```sh
kubectl get events --field-selector reason=DisruptionTerminating --sort-by=.lastTimestamp
```

Should show both NodeClaims with `Disrupting NodeClaim: Empty`.

---

### Step 5 — Switch to `Balanced` and repeat the same sequence

```sh
kubectl patch nodepool balanced-consolidation --type=merge \
  -p '{"spec":{"disruption":{"consolidationPolicy":"Balanced"}}}'
```

Now re-run steps 1–4 exactly the same way:

```sh
kubectl scale deployment balanced-inflate --replicas=5   # -> 1x c6a.2xlarge
# wait, verify
kubectl scale deployment balanced-inflate --replicas=10  # -> +1x c6a.xlarge (2 nodes)
# wait, verify
kubectl scale deployment balanced-inflate --replicas=3   # -> replace 2xlarge with xlarge -> 2x c6a.xlarge
# wait, verify
kubectl scale deployment balanced-inflate --replicas=0   # -> both nodes removed (empty)
```

**Under Balanced you should see the identical node states** at each step. Balanced doesn't break beneficial consolidation — the replace in step 3 has real cost savings and passes the score gate (`score >= 0.5`), so it's approved just like it was under `WhenEmptyOrUnderutilized`.

Where Balanced diverges is on **marginal** moves — cases where the replace would produce near-zero savings for meaningful pod eviction. Those get rejected with score < 0.5. In a small demo cluster with a simple workload, it's hard to construct such a case deterministically (the `2xlarge → xlarge` savings in this walkthrough are substantial, so it always passes), but Karpenter emits an `Unconsolidatable: Can't replace with a cheaper node` event once the pool has reached its cheapest feasible shape:

```sh
kubectl get events --field-selector reason=Unconsolidatable --sort-by=.lastTimestamp
```

That event tells you Karpenter's feasibility check ran but couldn't find a cheaper replacement — under Balanced this is the point where the score gate has settled the pool into a stable low-cost configuration.

### Step 6 — Priority-weighted disruption

The clearest observable difference Balanced brings over `WhenEmptyOrUnderutilized` is that pod priority now feeds into consolidation ranking. When Karpenter has to pick which of several similar nodes to consolidate, Balanced prefers to disrupt nodes hosting **lower-priority** pods.

The two priority deployments (`balanced-inflate-lowpri`, `balanced-inflate-highpri`) carry mutual `podAntiAffinity` on `topologyKey: kubernetes.io/hostname`, so each tier lands on its own node. That makes the outcome deterministic: we can point at "the low-pri node" and "the high-pri node" without reasoning about pod packing on a shared instance.

Ensure the pool is on Balanced and the baseline deployment is at 0. Scale up both priority-classed deployments:

```sh
kubectl scale deployment balanced-inflate-highpri --replicas=3
kubectl scale deployment balanced-inflate-lowpri  --replicas=3
```

The pods carry:

```yaml
# balanced-inflate-highpri
spec:
  template:
    spec:
      priorityClassName: balanced-blueprint-high   # value 1000
      nodeSelector: {blueprint: balanced-consolidation}
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources: {requests: {cpu: "1", memory: "1Gi"}}
```

```yaml
# balanced-inflate-lowpri — identical shape, priorityClassName: balanced-blueprint-low (value 100)
```

Karpenter provisions two `xlarge` nodes — one holding the high-priority pods, one the low-priority pods. Verify placement:

```sh
kubectl get pods -l blueprint=balanced-consolidation \
  -o custom-columns=NAME:.metadata.name,PRIORITY:.spec.priorityClassName,NODE:.spec.nodeName
```

Now scale the low-priority deployment down:

```sh
kubectl scale deployment balanced-inflate-lowpri --replicas=0
```

Because Balanced weights disruption by pod priority, the low-priority node's `disruption_fraction` is smaller — its consolidation score clears the threshold and it's removed. The high-priority node stays. If the pool were on `WhenEmptyOrUnderutilized`, the outcome is the same in this case (the low-pri node became empty). The differentiator becomes visible when *both* nodes are underutilized but not empty; Balanced picks the low-priority host to consolidate first, `WhenEmptyOrUnderutilized` picks by scheduling simulation alone.

## Automated verification

`test.sh` runs the four scenarios from this walkthrough end-to-end and asserts on **specific NodeClaim identities** (not just counts or cluster-wide events), so unrelated activity elsewhere in the cluster can't make it pass or fail:

- **Test 1 — Provisioning + empty-node consolidation** (Steps 1 and 4). Scales the baseline to 5 then back to 0; asserts a NodeClaim appears then disappears.
- **Test 2 — Replace transition** (Steps 1–3). Scales 5 → 10 → 3; captures the original NodeClaim's name after step 1, then asserts that specific name is gone from the pool after Balanced replaces the oversized node.
- **Test 3 — Priority-weighted consolidation** (Step 6). Scales high-pri first, records its NodeClaim, then scales low-pri; asserts the low-pri NodeClaim (identified by which node hosts the low-pri pods) is the one consolidated when low-pri drops to 0.
- **Test 4 — Score gate / feasibility with a PDB**. Provisions a NodeClaim, pins its pods with `minAvailable: 100%`, and looks for `Unconsolidatable` / `ConsolidationRejected` / `DisruptionBlocked` events **against that specific NodeClaim** via `--field-selector involvedObject.name=<claim>`.

Run it against a cluster that meets the [Requirements](#requirements):

```sh
./test.sh
```

## Cleanup

```sh
kubectl delete -f workload.yaml
kubectl delete -f balanced-consolidation.yaml
```

## Takeaways

- **Same beneficial consolidation.** For clearly-beneficial actions (empty-node deletes, replaces with substantial savings), Balanced approves them at the same score threshold and produces the same node states as `WhenEmptyOrUnderutilized`.
- **Score gate for marginal moves.** The score gate protects against churny replaces where savings barely cover disruption. In this demo the sequence's actions clear the gate; on real workloads with more nodes and tighter cost ratios, the gate rejects moves that `WhenEmptyOrUnderutilized` would have taken.
- **Priority is now a first-class signal.** `PriorityClass` values you probably already use for scheduling now also protect their pods' host nodes from being picked first when consolidation has multiple candidates.
- **Budget windows can relax.** If you had scheduled `disruption.budgets` with `nodes: 0` windows to contain churn, Balanced removes much of the reason to. Windows still matter for high-blast-radius operations (drift, expiration), but consolidation-driven churn is now bounded by the score gate.

## References

- Karpenter release notes: [v1.14.0](https://github.com/aws/karpenter-provider-aws/releases/tag/v1.14.0)
- Karpenter disruption docs: [karpenter.sh/docs/concepts/disruption](https://karpenter.sh/docs/concepts/disruption/#balanced-consolidation)
- Balanced consolidation RFC: [designs/balanced-consolidation.md](https://github.com/kubernetes-sigs/karpenter/blob/main/designs/balanced-consolidation.md)
- Consolidation lab in the AWS workshop: [Karpenter consolidation](https://catalog.us-east-1.prod.workshops.aws/workshops/f6b4587e-b8a5-4a43-be87-26bd85a70aba/en-US/050-karpenter/consolidation)
