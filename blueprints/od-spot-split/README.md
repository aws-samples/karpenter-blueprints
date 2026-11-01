# Karpenter Blueprint: Split Between On-Demand & Spot Instances

## Purpose

This setup works if you're interested in having a portion the EKS nodes running using On-Demand instances, and another portion on Spot. For example, a split of 20% On-Demand, and 80% on Spot. You're can take advantage of the labels Karpenter adds automatically to each node, and use [Topology Spread Constraints (TSC)](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) within a `Deployment` or `Pod` to split capacity in a desired ratio.

To do this, you can create a NodePool each for Spot and On-Demand with disjoint values for a unique new label called `capacity-spread`. Then, assign values to this label to configure the split. If you'd like to have a 20/80 split, you could add the values `["2","3","4","5"]` for the Spot NodePool, and `["1"]` for the On-Demand NodePool.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter NodePool as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.

## Deploy

To deploy the Karpenter `NodePool` and the sample `workload`, simply run this command:

```sh
kubectl apply -f .
```

You should see the following output:

```console
nodepool.karpenter.sh/node-od created
nodepool.karpenter.sh/node-spot created
deployment.apps/workload-split created
```

## Results

You can review the Karpenter logs and watch how it's deciding to launch multiple nodes following the workload constraints:

```sh
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true -f --tail=20
```

Wait one minute and you should see the pods running within multiple nodes, run this command:

```sh
kubectl get nodes -L karpenter.sh/capacity-type,beta.kubernetes.io/instance-type,karpenter.sh/nodepool,topology.kubernetes.io/zone -l karpenter.sh/initialized=true
```

You should see an output similar to this:

```console
NAME                                         STATUS   ROLES    AGE     VERSION               CAPACITY-TYPE   INSTANCE-TYPE    NODEPOOL    ZONE
ip-10-0-104-249.eu-west-2.compute.internal   Ready    <none>   17s     v1.34.1-eks-473151a   spot            c7i-flex.large   node-spot   eu-west-2c
ip-10-0-40-176.eu-west-2.compute.internal    Ready    <none>   6m29s   v1.34.1-eks-473151a   spot            m7g.xlarge       default     eu-west-2a
ip-10-0-47-113.eu-west-2.compute.internal    Ready    <none>   6m29s   v1.34.1-eks-473151a   spot            m7g.xlarge       default     eu-west-2a
ip-10-0-53-185.eu-west-2.compute.internal    Ready    <none>   6m29s   v1.34.1-eks-473151a   spot            m7g.xlarge       default     eu-west-2a
ip-10-0-54-129.eu-west-2.compute.internal    Ready    <none>   6m29s   v1.34.1-eks-473151a   spot            m7g.xlarge       default     eu-west-2a
ip-10-0-83-213.eu-west-2.compute.internal    Ready    <none>   20s     v1.34.1-eks-473151a   on-demand       c6a.large        node-od     eu-west-2b
```

As you can see, pods were spread within the `spot` and `od` nodepools because of the `capacity-spread` TSC:

```yaml
      topologySpreadConstraints:
        - labelSelector:
            matchLabels:
              app: workload-split
          maxSkew: 1
          topologyKey: capacity-spread
          whenUnsatisfiable: DoNotSchedule
```

And each `NodePool` has a weight configured, the `od` NodePool has the following requirement:

```yaml
    - key: capacity-spread
      operator: In
      values: ["1"]
```

And the `spot` has the following requirement:

```yaml
    - key: capacity-spread
      operator: In
      values: ["2","3","4","5"]
```

### Keeping Spot diversified with `minValues`

Spot works best when EC2 can pick from many capacity pools. The `node-spot` NodePool allows hundreds of instance types, but the set Karpenter actually sends to EC2 Fleet for a given launch can be much narrower: pod constraints, consolidation, and cached `InsufficientInstanceCapacity` errors all trim it. Launching into only one or two pools raises the chance of interruptions and failed launches.

[`minValues`](https://karpenter.sh/docs/concepts/nodepools/#min-values) sets a floor on that flexibility. The `node-spot` NodePool requires every launch to span at least 2 instance categories, 5 instance families, and 15 instance types:

```yaml
    - key: karpenter.k8s.aws/instance-category
      operator: In
      values: ["c", "m", "r"]
      minValues: 2
    - key: karpenter.k8s.aws/instance-family
      operator: Exists
      minValues: 5
    - key: node.kubernetes.io/instance-type
      operator: Exists
      minValues: 15
```

The 15 instance types also match the minimum Karpenter needs before it will do [Spot-to-Spot consolidation](https://karpenter.sh/docs/concepts/disruption/#spot-consolidation), so the same floor covers both launches and replacements. The `node-od` NodePool doesn't set `minValues`, because On-Demand capacity isn't reclaimed and cheapest-first is usually what you want there.

You can check how diversified a launch was by looking at the requirements Karpenter recorded on a Spot NodeClaim:

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=node-spot \
  -o jsonpath='{.items[0].spec.requirements[?(@.key=="node.kubernetes.io/instance-type")]}' | jq '{minValues, count: (.values | length)}'
```

The `count` should be at least `15`.

When Karpenter can't meet a `minValues` floor, what happens next depends on the controller's `--min-values-policy` setting (Helm: `settings.minValuesPolicy`). With `Strict`, the default, Karpenter won't launch from this NodePool and the pods stay pending, or fall back to another NodePool if one matches. With `BestEffort`, Karpenter lowers the floor until a launch succeeds. Keep `Strict` if a narrow Spot launch is worse for you than a short delay.

<details>
<summary><strong>EKS Auto Mode</strong></summary>

**Prerequisite:** an EKS cluster with Auto Mode enabled, and an EKS Access Entry granting `AmazonEKSAutoNodePolicy` to the node IAM role used by Auto Mode.

> If you're using the Terraform template under [`cluster/automode/`](../../cluster/automode/) in this repo, the cluster, node IAM role, and Access Entry are all created for you — you can skip the manual access entry steps below.

To deploy this blueprint on Auto Mode, use the `-automode.yaml` manifest instead of the OSS one:

```sh
kubectl apply -f od-spot-automode.yaml
```

Differences from the OSS version:
- `NodeClass` (`eks.amazonaws.com/v1`) replaces `EC2NodeClass` (`karpenter.k8s.aws/v1`)
- `amiFamily`, `amiSelectorTerms`, `role`, `metadataOptions`, and `blockDeviceMappings` are removed — Auto Mode manages these
- Instance label keys use the `eks.amazonaws.com/` prefix instead of `karpenter.k8s.aws/`

If you are **not** using the `cluster/automode/` Terraform template, configure the Access Entry manually:

```sh
aws eks create-access-entry \
  --cluster-name $CLUSTER_NAME \
  --principal-arn <node-role-arn> \
  --type EC2

aws eks associate-access-policy \
  --cluster-name $CLUSTER_NAME \
  --principal-arn <node-role-arn> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy \
  --access-scope type=cluster
```
</details>

## Cleanup

```sh
kubectl delete -f workload.yaml
kubectl delete -f od-spot.yaml
```
