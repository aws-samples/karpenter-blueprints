# Karpenter Blueprint: Prioritize Savings Plans and/or Reserved Instances

## Purpose
You might want to consume your Saving Plans and/or Reserved Instances before any other purchase model when using Karpenter. Currently, to cover this scenario you need to have a prioritized NodePool for the reserved instances. This NodePool needs to have a high weight configuration to tell Karpenter to user this NodePool first, along with a `limits` configuration to limit the number of EC2 instances to launch. When this NodePool meet the limits, Karpenter will continue launching instances from other NodePools, typically from the `default` one.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A list of instance types or families that match with your Savings Plans and/or Reserved Instances, along with the total number of vCPUs you've reserved.
* A `default` Karpenter `NodePool` as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.

## Deploy
Let's suppose you purchased a Saving Plans of 20 vCPUs for `c4` family. Your NodePool should look like this:

```
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: savings-plans
spec:
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
  limits:
    cpu: "20" # For example: Limit to launch up to 5 c4.xlarge instances
  template:
    metadata:
      labels:
        intent: apps
    spec:
      expireAfter: 168h0m0s
      nodeClassRef:
        group: karpenter.k8s.aws
        name: default
        kind: EC2NodeClass
      requirements:
      - key: karpenter.k8s.aws/instance-family
        operator: In
        values:
        - c4
      - key: kubernetes.io/os
        operator: In
        values:
        - linux
      - key: kubernetes.io/arch
        operator: In
        values:
        - amd64
      - key: karpenter.sh/capacity-type
        operator: In
        values:
        - on-demand
  weight: 100
```

Notice that the above `NodePool` has a `weight` configuration of `100` and a `cpu` limit of 20 (5 x c4.xlarge instances).

Deploy the prioritized NodePool and the sample workload with 20 pods requesting `950m` cpu units:

```
kubectl apply -f savings-plans.yaml
kubectl apply -f workload.yaml
```

## Results
Wait around three minutes to get all the pods running. Run the following command to see the nodes launched by Karpenter including the `NodePool-name` column to see which `NodePool` was used:

```
kubectl get nodes -L karpenter.sh/capacity-type,beta.kubernetes.io/instance-type,karpenter.sh/nodepool,topology.kubernetes.io/zone -l karpenter.sh/initialized=true
```

You should get a similar output like this:

```
NAME                                         STATUS   ROLES    AGE   VERSION               CAPACITY-TYPE   INSTANCE-TYPE   NODEPOOL        ZONE
ip-10-0-119-235.eu-west-2.compute.internal   Ready    <none>   23s   v1.33.0-eks-802817d   on-demand       c4.4xlarge      savings-plans   eu-west-2c
ip-10-0-127-154.eu-west-2.compute.internal   Ready    <none>   35m   v1.33.0-eks-802817d   on-demand       c6g.xlarge      default         eu-west-2c
ip-10-0-78-33.eu-west-2.compute.internal     Ready    <none>   24s   v1.33.0-eks-802817d   on-demand       c4.xlarge       savings-plans   eu-west-2b
```

Notice how the `savings-plans` NodePool launched all the capacity it could. Two instances: `c4.xlarge` (4 vCPUs) and `c4.4xlarge` (16 vCPUs), which together reach the limit of 20 vCPUs you configured for this NodePool. Additionally, you see Karpenter launched a `c5.large` Spot instance for the rest of the pods using the `default` NodePool. Remember, each node always launch the `kubelet` and `kube-proxy` pods, that's why by Karpenter launched an extra node because 20 vCPUs of reserved capacity wasn't enough if system pods need to be included.

## Cleanup
To remove all objects created, simply run the following commands:

```
kubectl delete -f .
```
