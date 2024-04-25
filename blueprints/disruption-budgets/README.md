# Karpenter Blueprint: NodePool Disruption Budgets

## Purpose

Karpenter's actions like consolidation, drift detection and `expireAfter`, allow users to optimize for cost in the case of consolidation, keep up with the latest security patches and desired configuration, or ensure governance best practices, like refreshing instances every N days. These actions cause, as a trade-off, some level of disruption in the cluster caused by expected causes. To control the trade-off between, for example, being on the latest AMI (drift detection) and nodes restarting when that happens we can use disruption controls and confgiure disruption budgets in the Karpenter NodePool configuration. If no disruption budget is configured their is a default of 10%. When calculating if a budget will block nodes from disruption, Karpenter checks if the number of nodes being deleted is greater than the number of allowed disruptions. Budgets take into consideration voluntary disruptions through expiration, drift, emptiness and consolidation. If there are multiple budgets defined in the NodePool, Karpenter will honour the most restrictive of the budgets.

By applying a combination of disruptions budgets and Pod Disruptions Budgets (PDBs) you get both application and platform voluntary disruption controls, this can help you move towards continually operations to protect workload availability. You can learn more about Karpenter NodePool disruption budges and how the Kapenter disruption controllers works in the [Karpenter documentation](https://karpenter.sh/docs/concepts/disruption/#disruption-controller).

## Examples
The following provides a set of example disruption budgets:

### Only interrupt a % of Karpenter managed nodes

Applications or systems might be more affected by planned disruptions caused by consolidation. Some application may find consolidation is either too aggressive, while other might be more fault tolerant and would rather optimize for cost. This configuration to only interrupt a percentage of managed nodes allows you to control the level of churn. This also applies for cases like expireAfter, where there is an intent to refresh nodes.

The following Disruption Budgets says, at any-point in time only disrupt 20% of the Nodes managed by the NodePool. For instance, if there were 19 nodes owned by the NodePool, 4 disruptions would be allowed, rounding up from 19 * .2 = 3.8.

```
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  ...
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h # 30 days
    budgets:
    - nodes: "20%"
```

### Do not disrupt between UTC 09:00 and 18:00 every day

You might apply this configuration if you would not like Karpenter to not dirupt workloads during times when the workload might be receiving peak traffic.

The following Disruption Budgets says, for a 8 hour timeframe from UTC 9:00 don’t disrupt any nodes voluntary.

```
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default-block-disruptions-during-standard-hours
spec:
  ...
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h # 30 days
    budgets:
    - nodes: "0"
      schedule: "0 9 * * *"
      duration: 8h
```

### Allow 20% disruptions during a maintenance window from UTC 22:00 to 2:00, but only 10% disruptions outside of a maintenance window

The following Disruption Budgets says, for a 4 hour timeframe from UTC 22:00 only disrupt 20% of nodes, but during normal operations only disrupt 10% of nodes.

```
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default-block-disruptions-during-maintenance-window
spec:
  ...
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h # 30 days
    budgets:
    - nodes: "20%"
      schedule: "0 22 * * *"
      duration: 4h
    - nodes: "10%"
```

### Multiple budgets defined

The following Disruption Budgets is an example of a NodePool with three budgets defined.

* The first budget will only allow 20% of nodes owned by that NodePool to be disrupted.
* The second budget acts as a ceiling to the previous budget, only allowing 5 disruptions
* The last budget only blocks disruptions during the first 10 minutes of the day, where 0 disruptions are allowed.

If multiple Budgets are active at the same time Karpenter will consider the most restrictive. You might consider multiple disruption budgets if you want to have a default disruption policy and would like an alternative policy at a specific time e.g. during maintenance windows allow more disruptions to roll-out new Amazon Machine Images faster.

```
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  ...
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h # 30 days
    budgets:
    - nodes: "20%"
    - nodes: "5"
    - nodes: "0"
      schedule: "@daily"
      duration: 10m
```

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the cluster folder in the root of this repository.

## Deploy

Let's say you want to control how nodes are upgraded when switching to Bottlerocket via Karpenter Drift, in this example we deploy a disruption budget, that prevents disruptions 24 hours a day 7 days a week. You can use the schedule and duration of the budget to control when disruptions via Drift can take place.

To deploy the Karpenter NodePool and the sample workload, simply run this command:

```
kubectl apply -f .
```

You should see the following output:

```
nodepool.karpenter.sh/default created
deployment.apps/workload-multi-az-nodes created
```

You should now see new nodes provisioned in your Amazon EKS cluster:

```
> kubectl get nodes

ip-10-0-10-118.eu-west-1.compute.internal           Ready    <none>   9m28s   v1.29.1-eks-61c0bbb
ip-10-0-10-175.eu-west-1.compute.internal           Ready    <none>   8m42s   v1.29.0-eks-5e0fdde
ip-10-0-10-208.eu-west-1.compute.internal           Ready    <none>   2m31s   v1.29.0-eks-5e0fdde
ip-10-0-10-83.eu-west-1.compute.internal            Ready    <none>   2m36s   v1.29.0-eks-5e0fdde
ip-10-0-11-194.eu-west-1.compute.internal           Ready    <none>   7m39s   v1.29.0-eks-5e0fdde
ip-10-0-11-201.eu-west-1.compute.internal           Ready    <none>   7m39s   v1.29.0-eks-5e0fdde
ip-10-0-11-54.eu-west-1.compute.internal            Ready    <none>   7m54s   v1.29.0-eks-5e0fdd
ip-10-0-12-40.eu-west-1.compute.internal            Ready    <none>   11m     v1.29.1-eks-61c0bbb
```

Now, use `kubectl edit ec2nodeclass/default` and change the `.spec.amiFamily` from `AL2` to `Bottlerocket`. 

## Results

This is an example of an overly restrictive budget for demo purposes as it will prevent any voluntary disruptions via emptiness, drift, emptiness and consolidation. We learn from this that the schedule states when the budget is first active and the duration specifies how long the budget is active - a duration must be specified if a schedule is set otherwise the budget is always active.

Karpenter will try to replace nodes via the Drift mechanism on an AMI change. However, if you watch the nodes, you’ll notice that they’re not being replaced with new instances provisioned with the Bottlerocket Amazon EKS optimized AMI.

```
> kubectl get nodes -o wide -w

ip-10-0-10-118.eu-west-1.compute.internal           Ready    ....  Amazon Linux 2
ip-10-0-10-175.eu-west-1.compute.internal           Ready    ....  Amazon Linux 2
ip-10-0-10-208.eu-west-1.compute.internal           Ready    ....  Amazon Linux 2
ip-10-0-10-83.eu-west-1.compute.internal            Ready    ....  Amazon Linux 2
ip-10-0-11-194.eu-west-1.compute.internal           Ready    ....  Amazon Linux 2
ip-10-0-11-201.eu-west-1.compute.internal           Ready    ....  Amazon Linux 2
ip-10-0-11-54.eu-west-1.compute.internal            Ready    ....  Amazon Linux 2
ip-10-0-12-40.eu-west-1.compute.internal            Ready    ....  Amazon Linux 2
```

You will also see the following message in Kubernetes events stating disruptions are blocked:

```
> kubectl get events -w

0s Normal DisruptionBlocked nodepool/default No allowed disruptions due to blocking budget
```

This is because the NodePool defines the following budget which states, starting at UTC 00:00 everyday, for a time period of 24 hours no nodes can be voluntary drifted. This is a great fit when you want consolidation but might not want to apply it all the time.

```
budgets:
    - nodes: "0"
      schedule: "0 0 * * *"
      duration: 24h
```

If you edit the NodePool and replace the budget with the following, Karpenter will be able to Drift 20% of the Nodes.

```
- nodes: "20%"
```

After modifying that budget for the NodePool you should observe the nodes drifting and new nodes being provisioned with the latest Amazon EKS optimized Bottlerocket AMI.

```
> kubectl get nodes -o wide -w

ip-10-0-10-115.eu-west-1.compute.internal           Ready    ....  Bottlerocket OS 1.19.4 (aws-k8s-1.29)
ip-10-0-10-176.eu-west-1.compute.internal           Ready    ....  Bottlerocket OS 1.19.4 (aws-k8s-1.29)
ip-10-0-10-209.eu-west-1.compute.internal           Ready    ....  Bottlerocket OS 1.19.4 (aws-k8s-1.29)
ip-10-0-10-84.eu-west-1.compute.internal            Ready    ....  Bottlerocket OS 1.19.4 (aws-k8s-1.29)
ip-10-0-11-194.eu-west-1.compute.internal           Ready    ....  Amazon Linux 2
ip-10-0-11-202.eu-west-1.compute.internal           Ready    ....  Bottlerocket OS 1.19.4 (aws-k8s-1.29)
ip-10-0-11-55.eu-west-1.compute.internal            Ready    ....  Bottlerocket OS 1.19.4 (aws-k8s-1.29)
ip-10-0-12-40.eu-west-1.compute.internal            Ready    ....  Amazon Linux 2
```

You will also see the following message in Kubernetes events stating a node has been drifted:

```
0s          Normal    DisruptionTerminating           node/ip-10-0-10-83.eu-west-1.compute.internal   Disrupting Node: Drift/Delete
0s          Normal    DisruptionTerminating           nodeclaim/default-lxx5r                          Disrupting NodeClaim: Drift/Delete
0s          Normal    RemovingNode                    node/ip-10-0-10-83.eu-west-1.compute.internal   Node ip-10-0-10-83.eu-west-1.compute.internal event: Removing Node ip-10-0-10-83.eu-west-1.compute.internal from Controller
```

## Clean-up

To remove all objects created, simply run the following commands:

```
kubectl delete -f .
```
