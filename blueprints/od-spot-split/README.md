# Karpenter Blueprint: Split Between On-Demand & Spot Instances

## Purpose

This setup works if you're interested in having a portion the EKS nodes running using On-Demand instances, and another portion on Spot. For example, a split of 20% On-Demand, and 80% on Spot. You're can take advantage of the labels Karpenter adds automatically to each node, and use [Topology Spread Constraints (TSC)](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) within a `Deployment` or `Pod` to split capacity in a desired ratio.

To do this, you can create a NodePool each for Spot and On-Demand with disjoint values for a unique new label called `capacity-spread`. Then, assign values to this label to configure the split. If you'd like to have a 20/80 split, you could add the values `["2","3","4","5"]` for the Spot NodePool, and `["1"]` for the On-Demand NodePool.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter NodePool as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.

## Deploy
To deploy the Karpenter `NodePool` and the sample `workload`, simply run this command:

```
kubectl apply -f .
```

You should see the following output:

```
nodepool.karpenter.sh/node-od created
nodepool.karpenter.sh/node-spot created
deployment.apps/workload-split created
```

## Results

You can review the Karpenter logs and watch how it's deciding to launch multiple nodes following the workload constraints:

```
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true -f --tail=20
```

Wait one minute and you should see the pods running within multiple nodes, run this command:

```
kubectl get nodes -L karpenter.sh/capacity-type,beta.kubernetes.io/instance-type,karpenter.sh/nodepool,topology.kubernetes.io/zone -l karpenter.sh/initialized=true
```

You should see an output similar to this:

```
NAME                                         STATUS   ROLES    AGE     VERSION               CAPACITY-TYPE   INSTANCE-TYPE    NODEPOOL    ZONE
ip-xxx-xxx-xxx-xxx.eu-west-2.compute.internal   Ready    <none>   17s     v1.33.0-eks-802817d   spot            c7i-flex.large   node-spot   eu-west-2c
ip-xxx-xxx-xxx-xxx.eu-west-2.compute.internal    Ready    <none>   6m29s   v1.33.0-eks-802817d   spot            m7g.xlarge       default     eu-west-2a
ip-xxx-xxx-xxx-xxx.eu-west-2.compute.internal    Ready    <none>   6m29s   v1.33.0-eks-802817d   spot            m7g.xlarge       default     eu-west-2a
ip-xxx-xxx-xxx-xxx.eu-west-2.compute.internal    Ready    <none>   6m29s   v1.33.0-eks-802817d   spot            m7g.xlarge       default     eu-west-2a
ip-xxx-xxx-xxx-xxx.eu-west-2.compute.internal    Ready    <none>   6m29s   v1.33.0-eks-802817d   spot            m7g.xlarge       default     eu-west-2a
ip-xxx-xxx-xxx-xxx.eu-west-2.compute.internal    Ready    <none>   20s     v1.33.0-eks-802817d   on-demand       c6a.large        node-od     eu-west-2b
```

As you can see, pods were spread within the `spot` and `od` nodepools because of the `capacity-spread` TSC:

```
      topologySpreadConstraints:
        - labelSelector:
            matchLabels:
              app: workload-split
          maxSkew: 1
          topologyKey: capacity-spread
          whenUnsatisfiable: DoNotSchedule
```

And each `NodePool` has a weight configured, the `od` NodePool has the following requirement:

```
    - key: capacity-spread
      operator: In
      values: ["1"]
```

And the `spot` has the following requirement:

```
    - key: capacity-spread
      operator: In
      values: ["2","3","4","5"]
```

## Cleanup

```
kubectl delete -f workload.yaml
kubectl delete -f od-spot.yaml
```
