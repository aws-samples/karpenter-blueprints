# Karpenter Blueprint: High-Availability - Spread Pods across AZs & Nodes

## Purpose
Karpenter can launch only one node for all pending pods. However, putting all application pods in the same node is not recommended if you want to have high-availability. To avoid this, and make the workload more highly-available, you can spread the pods within multiple availability zones (AZs). Additionally, you can configure a constraint to spread pods within multiple nodes in the same AZ. To do so, you configure [Topology Spread Constraints (TSC)](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) within a `Deployment` or `Pod`.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter `NodePool` as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.

## Deploy

To deploy the sample `workload`, simply run this command:

```
kubectl apply -f workload.yaml
```

## Results

You can review the Karpenter logs and watch how it's deciding to launch multiple nodes following the workload constraints:

```
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true -f --tail=20
```

Wait one minute and you should see the pods running within two nodes in each AZ, run this command:

```
kubectl get nodes -L karpenter.sh/capacity-type,beta.kubernetes.io/instance-type,karpenter.sh/nodepool,topology.kubernetes.io/zone -l karpenter.sh/initialized=true
```

You should see an output similar to this:

```
NAME                                         STATUS   ROLES    AGE     VERSION               CAPACITY-TYPE   INSTANCE-TYPE   NODEPOOL   ZONE
ip-10-0-120-103.eu-west-2.compute.internal   Ready    <none>   8m37s   v1.30.2-eks-1552ad0   on-demand       c6g.2xlarge     default    eu-west-2c
ip-10-0-37-198.eu-west-2.compute.internal    Ready    <none>   17s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2a
ip-10-0-37-31.eu-west-2.compute.internal     Ready    <none>   18s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2a
ip-10-0-40-3.eu-west-2.compute.internal      Ready    <none>   15s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2a
ip-10-0-42-68.eu-west-2.compute.internal     Ready    <none>   19s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2a
ip-10-0-42-79.eu-west-2.compute.internal     Ready    <none>   13s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2a
ip-10-0-44-133.eu-west-2.compute.internal    Ready    <none>   15s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2a
ip-10-0-45-41.eu-west-2.compute.internal     Ready    <none>   19s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2a
ip-10-0-47-216.eu-west-2.compute.internal    Ready    <none>   22s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2a
ip-10-0-52-31.eu-west-2.compute.internal     Ready    <none>   18s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2a
ip-10-0-56-207.eu-west-2.compute.internal    Ready    <none>   16s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2a
ip-10-0-70-74.eu-west-2.compute.internal     Ready    <none>   20s     v1.30.2-eks-1552ad0   spot            c7g.xlarge      default    eu-west-2b
ip-10-0-77-172.eu-west-2.compute.internal    Ready    <none>   18s     v1.30.2-eks-1552ad0   spot            c7g.xlarge      default    eu-west-2b
ip-10-0-78-211.eu-west-2.compute.internal    Ready    <none>   14s     v1.30.2-eks-1552ad0   spot            r6g.xlarge      default    eu-west-2b
ip-10-0-78-239.eu-west-2.compute.internal    Ready    <none>   21s     v1.30.2-eks-1552ad0   spot            m7g.xlarge      default    eu-west-2b
ip-10-0-83-77.eu-west-2.compute.internal     Ready    <none>   13s     v1.30.2-eks-1552ad0   spot            c5a.xlarge      default    eu-west-2b
ip-10-0-91-96.eu-west-2.compute.internal     Ready    <none>   16s     v1.30.2-eks-1552ad0   spot            c6gd.xlarge     default    eu-west-2b
```

As you can see, pods were spread within AZs (1a and 1b) because of the `topology.kubernetes.io/zone` TSC. But at the same time, pods were spread within multiple nodes in each AZ because of the `kubernetes.io/hostname` TSC.

```
      topologySpreadConstraints:
        - labelSelector:
            matchLabels:
              app: workload-multi-az-nodes
          maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
        - labelSelector:
            matchLabels:
              app: workload-multi-az-nodes
          maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
```

If you're using a region with more than two AZs available, you might have noticed that pods were scheduled only in two AZs. This is because you're setting `whenUnsatisfiable` to `ScheduleAnyway` which is a soft constraint, the `kube-scheduler` gives higher precedence to topologies that would help reduce the skew.

**NOTE**: If you strictly need to spread within all available AZs, you can set he `minDomains` to the number of AZs as this lets you tell the `kube-scheduler` that you expect there to be a particular number of AZs. Therefore, if `kube-scheduler` is not aware of all available AZs, pods are marked as unschedulable and Karpenter will launch a node in each AZ. However, it's important that you know that setting `whenUnsatisfiable` to `DoNotSchedule` will cause pods to be unschedulable if the topology spread constraint can't be fulfilled. It should only be set if its preferable for pods to not run instead of violating the topology spread constraint.

In case you want to enforce this spread within `Deployments`, you can use projects like [Kyverno](https://kyverno.io) to mutate a `Deployment` object and set the TSC you've seen in this blueprint. Here's a [Kyverno policy example](https://kyverno.io/policies/other/s-z/spread-pods-across-topology/spread-pods-across-topology/) that mutates a `Deployment` to include a TSC, just make sure it replicates the same rule from this blueprint (`whenUnsatisfiable` to `ScheduleAnyway`).
 
## Cleanup

```
kubectl delete -f workload.yaml
```