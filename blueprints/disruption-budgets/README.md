# Karpenter Blueprint: NodePool Disruption Budgets

## Purpose

Karpenter's actions like consolidation, drift detection and `expireAfter`, allow users to optimize for cost in the case of consolidation, keep up with the latest security patches and desired configuration, or ensure governance best practices, like refreshing instances every N days. These actions cause, as a trade-off, some level of disruption in the cluster caused by expected causes. To control the trade-off between, for example, being on the latest AMI (drift detection) and nodes restarting when that happens we can use disruption controls and configure `disruption budgets` in the Karpenter `NodePool` configuration. If no disruption budget is configured their is a default budget with `nodes: 10%`. When calculating if a budget will block nodes from disruption, Karpenter checks if the number of nodes being deleted is greater than the number of allowed disruptions. Budgets take into consideration voluntary disruptions through expiration, drift, emptiness and consolidation. If there are multiple budgets defined in the `NodePool`, Karpenter will honour the most restrictive of the budgets.

By applying a combination of disruptions budgets and Pod Disruptions Budgets (PDBs) you get both application and platform voluntary disruption controls, this can help you move towards continually operations to protect workload availability. You can learn more about Karpenter NodePool disruption budgets and how the Kapenter disruption controller works in the [Karpenter documentation](https://karpenter.sh/docs/concepts/disruption/#disruption-controller).

## Examples
The following provides a set of example disruption budgets:

### Limit Disruptions to a Percentage of Nodes

To prevent disruptions from affecting more than a certain percentage of nodes in a NodePool

The following Disruption Budgets says, at any-point in time only disrupt 20% of the Nodes managed by the NodePool. For instance, if there were 19 nodes owned by the NodePool, 4 disruptions would be allowed, rounding up from 19 * .2 = 3.8.

```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  ...
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    budgets:
    - nodes: "20%"
  template:
    spec:
      expireAfter: 720h # 30 days
```

### No Disruptions During Peak Hours

This configuration ensures that Karpenter avoids disrupting workloads during peak traffic periods. Specifically, it prevents disruptions from UTC 9:00 for an 8-hour window and limits disruptions to 20% outside of this window.

```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
    - nodes: "0"
      schedule: "0 9 * * *"
      duration: 8h
    - nodes: "20%"
      schedule: "0 17 * * *"
      duration: 16h
```

 ### Allow 20% disruptions during a maintenance window from UTC 22:00 to 2:00, but only 10% disruptions outside of a maintenance window

By setting multiple disruption budgets, you can gain precise control over node disruptions. Karpenter will use the most restrictive budget applicable at any given time.

In the following example, disruptions are limited to 20% of nodes during a 4-hour period starting from UTC 22:00. During the remaining hours (UTC 2:00 - 22:00), disruptions are limited to 10% of nodes.


```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
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

### Multiple Budgets Defined

The following configuration illustrates a NodePool with three disruption budgets:

The first budget allows up to 20% of nodes to be disrupted at any time.
The second budget imposes a maximum of 5 disruptions.
The third budget blocks all disruptions during the first 10 minutes of each day.

While the first and second budgets are always in effect, they work together to limit disruptions to a maximum of 5 nodes at any given time. Karpenter will apply the most restrictive budget when multiple budgets overlap, enabling flexible disruption policies for different scenarios, such as during maintenance windows.

> **Note:** If multiple budgets are active at the same time, Karpenter will consider the most restrictive budget. You might consider using multiple disruption budgets to establish a default policy while providing an alternative policy for specific times, such as allowing more disruptions during maintenance windows to roll out new Amazon Machine Images faster.

```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
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

### Disrupting by Reasons

Karpenter allows specifying if a budget applies to any of `Drifted`, `Underutilized`, or `Empty`. When a budget has no reasons, it’s assumed that it applies to all reasons. When calculating allowed disruptions for a given reason, Karpenter will take the minimum of the budgets that have listed the reason or have left reasons undefined.

#### Only Drifted Nodes
This example sets a budget that applies only to nodes classified as Drifted. During times when nodes are identified as Drifted, Karpenter will only disrupt up to 20% of those nodes.


```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: example-drifted
spec:
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    budgets:
    - nodes: "20%"
      reasons:
      - "Drifted"
```

#### Only Underutilized Nodes
This example sets a budget that applies only to nodes classified as Underutilized. During times when nodes are identified as Underutilized, Karpenter will only disrupt up to 30% of those nodes.

```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: example-underutilized
spec:
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    budgets:
    - nodes: "30%"
      reasons:
      - "Underutilized"
```

#### Only Empty Nodes
This example sets a budget that applies only to nodes classified as Empty. During times when nodes are identified as Empty, Karpenter will only disrupt up to 10% of those nodes.

```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: example-empty
spec:
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    budgets:
    - nodes: "10%"
      reasons:
      - "Empty"
```

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the cluster folder in the root of this repository.

## Deploy

Let's say you want to control how nodes are upgraded when switching to Bottlerocket via Karpenter Drift, in this example we deploy a disruption budget, that prevents disruptions 24 hours a day 7 days a week. You can use the schedule and duration of the budget to control when disruptions via Drift can take place.

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role(not the ARN).

To deploy the Karpenter NodePool and the sample workload, simply run this command:

```
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" disruption-budgets.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" disruption-budgets.yaml
kubectl apply -f .
```

You should see the following output:

```
nodepool.karpenter.sh/disruption-budget created
ec2nodeclass.karpenter.k8s.aws/disruption-budget created
deployment.apps/disruption-budget created
```

You should now see new nodes provisioned in your Amazon EKS cluster:

```
> kubectl get nodes
NAME                                         STATUS   ROLES    AGE     VERSION
ip-10-0-103-232.eu-west-2.compute.internal   Ready    <none>   2m8s    v1.32.2-eks-677bac1
ip-10-0-120-141.eu-west-2.compute.internal   Ready    <none>   2m44s   v1.32.2-eks-677bac1
ip-10-0-38-179.eu-west-2.compute.internal    Ready    <none>   2m8s    v1.32.2-eks-677bac1
ip-10-0-39-106.eu-west-2.compute.internal    Ready    <none>   2m18s   v1.32.2-eks-677bac1
ip-10-0-50-60.eu-west-2.compute.internal     Ready    <none>   17m     v1.32.2-eks-677bac1
ip-10-0-55-94.eu-west-2.compute.internal     Ready    <none>   2m47s   v1.32.2-eks-677bac1
ip-10-0-63-247.eu-west-2.compute.internal    Ready    <none>   2m40s   v1.32.2-eks-677bac1
ip-10-0-66-70.eu-west-2.compute.internal     Ready    <none>   17m     v1.32.2-eks-677bac1
ip-10-0-72-85.eu-west-2.compute.internal     Ready    <none>   2m50s   v1.32.2-eks-677bac1
ip-10-0-82-100.eu-west-2.compute.internal    Ready    <none>   2m29s   v1.32.2-eks-677bac1
ip-10-0-95-228.eu-west-2.compute.internal    Ready    <none>   2m19s   v1.32.2-eks-677bac1
ip-10-0-96-121.eu-west-2.compute.internal    Ready    <none>   2m26s   v1.32.2-eks-677bac1
```

Now, use the `kubectl patch` command to change `spec.amiSelectorTerms` alias from `al2023@latest` to `bottlerocket@latest`.

```
kubectl patch ec2nodeclass disruption-budget --type='json' -p='[
  {"op": "replace", "path": "/spec/amiSelectorTerms/0/alias", "value": "bottlerocket@latest"}
]'
```

## Results

This is an example of an overly restrictive budget for demo purposes as it will prevent any voluntary disruptions via emptiness, drift, emptiness and consolidation. We learn from this that the schedule states when the budget is first active and the duration specifies how long the budget is active - a duration must be specified if a schedule is set otherwise the budget is always active.

Karpenter will try to replace nodes via the Drift mechanism on an AMI change. However, if you watch the nodes, you’ll notice that they’re not being replaced with new instances provisioned with the Bottlerocket Amazon EKS optimized AMI.

```
> kubectl get nodes -o wide -w

NAME                                         STATUS   ROLES    AGE     VERSION               INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION                    CONTAINER-RUNTIME
ip-10-0-103-232.eu-west-2.compute.internal   Ready    <none>   3m22s   v1.32.2-eks-677bac1   10.0.103.232   <none>        Amazon Linux 2                 5.10.223-211.872.amzn2.aarch64    containerd://1.7.20
ip-10-0-120-141.eu-west-2.compute.internal   Ready    <none>   3m58s   v1.32.2-eks-677bac1   10.0.120.141   <none>        Amazon Linux 2                 5.10.223-211.872.amzn2.aarch64    containerd://1.7.20
ip-10-0-38-179.eu-west-2.compute.internal    Ready    <none>   3m22s   v1.32.2-eks-677bac1   10.0.38.179    <none>        Amazon Linux 2                 5.10.223-211.872.amzn2.aarch64    containerd://1.7.20
ip-10-0-39-106.eu-west-2.compute.internal    Ready    <none>   3m32s   v1.32.2-eks-677bac1   10.0.39.106    <none>        Amazon Linux 2                 5.10.223-211.872.amzn2.aarch64    containerd://1.7.20
ip-10-0-50-60.eu-west-2.compute.internal     Ready    <none>   18m     v1.32.2-eks-677bac1   10.0.50.60     <none>        Amazon Linux 2023.5.20240805   6.1.102-108.177.amzn2023.x86_64   containerd://1.7.20
ip-10-0-55-94.eu-west-2.compute.internal     Ready    <none>   4m1s    v1.32.2-eks-677bac1   10.0.55.94     <none>        Amazon Linux 2                 5.10.223-211.872.amzn2.aarch64    containerd://1.7.20
ip-10-0-63-247.eu-west-2.compute.internal    Ready    <none>   3m54s   v1.32.2-eks-677bac1   10.0.63.247    <none>        Amazon Linux 2                 5.10.223-211.872.amzn2.aarch64    containerd://1.7.20
ip-10-0-66-70.eu-west-2.compute.internal     Ready    <none>   18m     v1.32.2-eks-677bac1   10.0.66.70     <none>        Amazon Linux 2023.5.20240805   6.1.102-108.177.amzn2023.x86_64   containerd://1.7.20
ip-10-0-72-85.eu-west-2.compute.internal     Ready    <none>   4m4s    v1.32.2-eks-677bac1   10.0.72.85     <none>        Amazon Linux 2                 5.10.223-211.872.amzn2.x86_64     containerd://1.7.20
ip-10-0-82-100.eu-west-2.compute.internal    Ready    <none>   3m43s   v1.32.2-eks-677bac1   10.0.82.100    <none>        Amazon Linux 2                 5.10.223-211.872.amzn2.aarch64    containerd://1.7.20
ip-10-0-95-228.eu-west-2.compute.internal    Ready    <none>   3m33s   v1.32.2-eks-677bac1   10.0.95.228    <none>        Amazon Linux 2                 5.10.223-211.872.amzn2.aarch64    containerd://1.7.20
ip-10-0-96-121.eu-west-2.compute.internal    Ready    <none>   3m40s   v1.32.2-eks-677bac1   10.0.96.121    <none>        Amazon Linux 2                 5.10.223-211.872.amzn2.aarch64    containerd://1.7.20
```

You will also see the following message in Kubernetes events stating disruptions are blocked:

```
> kubectl get events -w

0s          Normal    DisruptionBlocked               nodepool/restrictive-budget                       No allowed disruptions for disruption reason Drifted due to blocking budget
0s          Normal    DisruptionBlocked               nodepool/restrictive-budget                       No allowed disruptions for disruption reason Underutilized due to blocking budget
0s          Normal    DisruptionBlocked               nodepool/restrictive-budget                       No allowed disruptions for disruption reason Empty due to blocking budget
0s          Normal    DisruptionBlocked               nodepool/restrictive-budget                       No allowed disruptions due to blocking budget
```

This is because the NodePool defines the following budget which states, starting at UTC 00:00 everyday, for a time period of 24 hours no nodes can be voluntary drifted. This is a great fit when you want consolidation but might not want to apply it all the time.

```
budgets:
    - nodes: "0"
      schedule: "0 0 * * *"
      duration: 24h
```

If you edit the NodePool and replace the budget with the following, Karpenter will be able to Drift 20% of the Nodes.

Edit with the `kubectl patch` command.
```
kubectl patch nodepool disruption-budget --type='json' -p='[
  {"op": "replace", "path": "/spec/disruption/budgets/0/nodes", "value": "20"}
]'
```

After modifying that budget for the NodePool you should observe the nodes drifting and new nodes being provisioned with the latest Amazon EKS optimized Bottlerocket AMI.

```
> kubectl get nodes -o custom-columns=NAME:.metadata.name,OS-IMAGE:.status.nodeInfo.osImage

NAME                                         OS-IMAGE
ip-10-0-103-176.eu-west-2.compute.internal   Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-106-25.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-108-51.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-115-104.eu-west-2.compute.internal   Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-116-220.eu-west-2.compute.internal   Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-121-123.eu-west-2.compute.internal   Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-43-37.eu-west-2.compute.internal     Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-50-60.eu-west-2.compute.internal     Amazon Linux 2023.5.20240805
ip-10-0-57-199.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-59-82.eu-west-2.compute.internal     Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-62-198.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-62-228.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-66-249.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-66-70.eu-west-2.compute.internal     Amazon Linux 2023.5.20240805
ip-10-0-67-142.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-67-203.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-67-255.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-68-97.eu-west-2.compute.internal     Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-70-55.eu-west-2.compute.internal     Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-73-112.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-75-130.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-77-110.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-78-43.eu-west-2.compute.internal     Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-91-17.eu-west-2.compute.internal     Bottlerocket OS 1.39.1 (aws-k8s-1.32)
ip-10-0-97-201.eu-west-2.compute.internal    Bottlerocket OS 1.39.1 (aws-k8s-1.32)
```

You will also see the following message in Kubernetes events stating a node has been drifted:

```
0s       Normal    DisruptionTerminating        node/ip-10-0-96-121.eu-west-2.compute.internal    Disrupting Node: Drifted/Delete
0s       Warning   InstanceTerminating          node/ip-10-0-96-121.eu-west-2.compute.internal    Instance is terminating
0s       Normal    RemovingNode                 node/ip-10-0-96-121.eu-west-2.compute.internal    Node ip-10-0-96-121.eu-west-2.compute.internal event: Removing Node ip-10-0-96-121.eu-west-2.compute.internal from Controller
```

## Clean-up

To remove all objects created, simply run the following commands:

```
kubectl delete -f .
```
