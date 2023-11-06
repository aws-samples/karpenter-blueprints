# Karpenter Blueprint: Prioritize Savings Plans and/or Reserved Instances

## Purpose
You might want to consume your Saving Plans and/or Reserved Instances before any other purchase model when using Karpenter. Currently, to cover this scenario you need to have a prioritized provisioner for the reserved instances. This provisioner needs to have a high weight configuration to tell Karpenter to user this provisioner first, along with a `limits` configuration to limit the number of EC2 instances to launch. When this provisioner meet the limits, Karpenter will continue launching instances from other provisioners, typically from the `default` one.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A list of instance types or families that match with your Savings Plans and/or Reserved Instances, along with the total number of vCPUs you've reserved.
* A `default` Karpenter provisioner as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default NodePool"](../../README.md) section from this repository.

## Deploy
Let's suppose you purchased a Saving Plans of 20 vCPUs for `c4` family. Your provisioner should look like this:

```
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: savings-plans
spec:
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 168h0m0s
  limits:
    cpu: "20"
  template:
    metadata:
      labels:
        intent: apps
    spec:
      nodeClassRef:
        name: default
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

Deploy the prioritized provisioner and the sample workload with 20 pods requesting `950m` cpu units:

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
NAME                                        STATUS   ROLES    AGE     VERSION               CAPACITY-TYPE   INSTANCE-TYPE   PROVISIONER-NAME   ZONE
ip-10-0-118-17.eu-west-1.compute.internal   Ready    <none>   5m46s   v1.27.4-eks-8ccc7ba   on-demand       c4.4xlarge      savings-plans      eu-west-1c
ip-10-0-121-24.eu-west-1.compute.internal   Ready    <none>   5m47s   v1.27.4-eks-8ccc7ba   on-demand       c4.xlarge       savings-plans      eu-west-1c
ip-10-0-49-93.eu-west-1.compute.internal    Ready    <none>   5m48s   v1.27.4-eks-8ccc7ba   spot            c5.large        default            eu-west-1a
```

Notice how the `savings-plans` provisioner launched all the capacity it could. Two instances: `c4.xlarge` (4 vCPUs) and `c4.4xlarge` (16 vCPUs), which together reach the limit of 20 vCPUs you configured for this provisioner. Additionally, you see Karpenter launched a `c5.large` Spot instance for the rest of the pods using the `default` provisioner. Remember, each node always launch the `kubelet` and `kube-proxy` pods, that's why by Karpenter launched an extra node because 20 vCPUs of reserved capacity wasn't enough if system pods need to be included.

## Cleanup
To remove all objects created, simply run the following commands:

```
kubectl delete -f .
```