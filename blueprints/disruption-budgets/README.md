# Karpenter Blueprint: NodePool Disruption Budgets

## Purpose

Karpenter's actions like consolidation, drift detection and `expireAfter`, allow users to optimize for cost in the case of consolidation, keep up with the latest security patches and desired configuration, or ensure governance best practices, like refreshing instances every N days. These actions cause, as a trade-off, some level of disruption in the cluster caused by expected causes. To control the trade-off between, for example, being on the latest AMI (drift detection) and nodes restarting when that happens we can use disruption controls and configure `disruption budgets` in the Karpenter `NodePool` configuration. If no disruption budget is configured their is a default budget with `nodes: 10%`. When calculating if a budget will block nodes from disruption, Karpenter checks if the number of nodes being deleted is greater than the number of allowed disruptions. Budgets take into consideration voluntary disruptions through expiration, drift, emptiness and consolidation. If there are multiple budgets defined in the `NodePool`, Karpenter will honour the most restrictive of the budgets.

By applying a combination of disruptions budgets and Pod Disruptions Budgets (PDBs) you get both application and platform voluntary disruption controls, this can help you move towards continually operations to protect workload availability. You can learn more about Karpenter NodePool disruption budgets and how the Kapenter disruption controller works in the [Karpenter documentation](https://karpenter.sh/docs/concepts/disruption/#disruption-controller).

## Examples
The following provides a set of example disruption budgets:

### Only interrupt a % of Karpenter managed nodes

Applications or systems might be more affected by planned disruptions caused by consolidation. Some applications may find consolidation is either too aggressive, while other might be more fault tolerant and would rather optimize for cost. This configuration to only interrupt a percentage of managed nodes allows you to control the level of churn. This also applies for cases like expireAfter, where there is an intent to refresh nodes.

The following Disruption Budgets says, at any-point in time only disrupt 20% of the Nodes managed by the NodePool. For instance, if there were 19 nodes owned by the NodePool, 4 disruptions would be allowed, rounding up from 19 * .2 = 3.8.

```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  ...
  disruption:
    consolidationPolicy: WhenUnderutilized
    budgets:
    - nodes: "20%"
  template:
    spec:
      expireAfter: 720h # 30 days
```

### Do not disrupt between UTC 09:00 and 18:00 every day

You might apply this configuration if you would like Karpenter to not disrupt workloads during times when the workload might be receiving peak traffic.

The following Disruption Budgets says, for a 8 hour timeframe from UTC 9:00 don’t disrupt any nodes voluntary, otherwise disrupt only 20%.

```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
...
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
    - nodes: "0"
      schedule: "0 0 * * *"
      duration: 24h
```

### Allow 20% disruptions during a maintenance window from UTC 22:00 to 2:00, but only 10% disruptions outside of a maintenance window

You might apply this configuration if outside of core business hours you prefer a higher set of disruptions to speed up the roll out of AMI updates for example.

The following Disruption Budgets says, for a 4 hour timeframe from UTC 22:00 only disrupt 20% of nodes, but during normal operations (UTC 2:00 - 22:00) only disrupt 10% of nodes.

```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  ...
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
    - nodes: "20%"
      schedule: "0 22 * * *"
      duration: 4h
    - nodes: "10%"
      schedule: "0 2 * * *"
      duration: 20h
```

### Multiple budgets defined

The following Disruption Budgets is an example of a NodePool with three budgets defined.

* The first budget will only allow 20% of nodes owned by that NodePool to be disrupted.
* The second budget acts as a ceiling to the previous budget, only allowing 5 disruptions
* The last budget only blocks disruptions during the first 10 minutes of the day, where 0 disruptions are allowed.

As the first and second budget are active all the time, though 20% of nodes can be disrupted only a maximum of 5 can be disrupted at anyone time.

If multiple Budgets are active at the same time Karpenter will consider the most restrictive. You might consider multiple disruption budgets if you want to have a default disruption policy and would like an alternative policy at a specific time e.g. during maintenance windows allow more disruptions to roll-out new Amazon Machine Images faster.

```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  ...
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
    - nodes: "20%"
    - nodes: "5"
    - nodes: "0"
      schedule: "@daily"
      duration: 10m
```

### Reasons

Karpenter allows specifying if a budget applies to any of `Drifted`, `Underutilized`, or `Empty`. When a budget has no reasons, it’s assumed that it applies to all reasons. When calculating allowed disruptions for a given reason, Karpenter will take the minimum of the budgets that have listed the reason or have left reasons undefined.


```
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    budgets:
    - nodes: "20%"
      reasons: 
      - "Empty"
      - "Drifted"
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

ip-10-0-101-25.eu-west-2.compute.internal    Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-104-11.eu-west-2.compute.internal    Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-116-117.eu-west-2.compute.internal   Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-116-255.eu-west-2.compute.internal   Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-35-96.eu-west-2.compute.internal     Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-36-126.eu-west-2.compute.internal    Ready    <none>   157m   v1.30.2-eks-1552ad0
ip-10-0-36-30.eu-west-2.compute.internal     Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-36-76.eu-west-2.compute.internal     Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-37-189.eu-west-2.compute.internal    Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-39-6.eu-west-2.compute.internal      Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-59-135.eu-west-2.compute.internal    Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-62-80.eu-west-2.compute.internal     Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-64-185.eu-west-2.compute.internal    Ready    <none>   157m   v1.30.2-eks-1552ad0
ip-10-0-67-159.eu-west-2.compute.internal    Ready    <none>   26m    v1.30.2-eks-1552ad0
ip-10-0-69-0.eu-west-2.compute.internal      Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-80-111.eu-west-2.compute.internal    Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-85-60.eu-west-2.compute.internal     Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-93-130.eu-west-2.compute.internal    Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-93-72.eu-west-2.compute.internal     Ready    <none>   13m    v1.30.2-eks-1552ad0
ip-10-0-96-223.eu-west-2.compute.internal    Ready    <none>   13m    v1.30.2-eks-1552ad0
```

Now, use `kubectl edit ec2nodeclass/default` and change the `.spec.amiFamily` from `AL2` to `Bottlerocket`. 

## Results

This is an example of an overly restrictive budget for demo purposes as it will prevent any voluntary disruptions via emptiness, drift, emptiness and consolidation. We learn from this that the schedule states when the budget is first active and the duration specifies how long the budget is active - a duration must be specified if a schedule is set otherwise the budget is always active.

Karpenter will try to replace nodes via the Drift mechanism on an AMI change. However, if you watch the nodes, you’ll notice that they’re not being replaced with new instances provisioned with the Bottlerocket Amazon EKS optimized AMI.

```
> kubectl get nodes -o wide -w

NAME                                         STATUS   ROLES    AGE    VERSION               INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION                    CONTAINER-RUNTIME
ip-10-0-101-25.eu-west-2.compute.internal    Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.101.25    <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-104-11.eu-west-2.compute.internal    Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.104.11    <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-116-117.eu-west-2.compute.internal   Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.116.117   <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-116-255.eu-west-2.compute.internal   Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.116.255   <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-35-96.eu-west-2.compute.internal     Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.35.96     <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-36-126.eu-west-2.compute.internal    Ready    <none>   157m   v1.30.2-eks-1552ad0   10.0.36.126    <none>        Amazon Linux 2023.5.20240805   6.1.102-108.177.amzn2023.x86_64   containerd://1.7.20
ip-10-0-36-30.eu-west-2.compute.internal     Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.36.30     <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-36-76.eu-west-2.compute.internal     Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.36.76     <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-37-189.eu-west-2.compute.internal    Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.37.189    <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-39-6.eu-west-2.compute.internal      Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.39.6      <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-59-135.eu-west-2.compute.internal    Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.59.135    <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-62-80.eu-west-2.compute.internal     Ready    <none>   14m    v1.30.2-eks-1552ad0   10.0.62.80     <none>        Amazon Linux 2                 5.10.220-209.869.amzn2.aarch64    containerd://1.7.11
ip-10-0-64-185.eu-west-2.compute.internal    Ready    <none>   157m   v1.30.2-eks-1552ad0   10.0.64.185    <none>        Amazon Linux 2023.5.20240805   6.1.102-108.177.amzn2023.x86_64   containerd://1.7.20
...
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

ip-10-0-10-115.eu-west-1.compute.internal           Ready    ....  Bottlerocket OS 1.19.4 (aws-k8s-1.30)
ip-10-0-10-176.eu-west-1.compute.internal           Ready    ....  Bottlerocket OS 1.19.4 (aws-k8s-1.30)
ip-10-0-10-209.eu-west-1.compute.internal           Ready    ....  Bottlerocket OS 1.19.4 (aws-k8s-1.30)
ip-10-0-10-84.eu-west-1.compute.internal            Ready    ....  Bottlerocket OS 1.19.4 (aws-k8s-1.30)
ip-10-0-11-194.eu-west-1.compute.internal           Ready    ....  Amazon Linux 2
...
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
