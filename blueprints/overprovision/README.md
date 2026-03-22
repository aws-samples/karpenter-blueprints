# Karpenter Blueprint: Overprovision capacity in advance to increase responsiveness

## Note

Starting in v1.8.0, Karpenter natively supports [static capacity](https://karpenter.sh/docs/concepts/nodepools/#static-nodepool), an [Alpha feature gate](https://karpenter.sh/docs/reference/settings/#feature-gates) that maintains a fixed node count regardless of pod demand. Static capacity addresses these use cases: 

1. Performance-critical applications where just-in-time provisioning latency is unacceptable
2. Workloads that require predictable, always-available capacity
3. Operational models that rely on a fixed number of nodes for budgeting, isolation, or infrastructure boundary

Static capacity does not scale nodes to keep overprovision. Use this blueprint, if your use case requires keeping your cluster overprovisioned.

## Purpose

Let's say you have a data pipeline process that knows it needs to launch 100 pods at the same time. To reduce the initiation time, you overprovision capacity in advance to increase responsiveness so when the data pipeline launches the pods, the capacity is already there.

To achieve this, you deploy a "dummy" workload with a low [PriorityClass](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/#priorityclass) to reserve capacity (to make Karpenter launch nodes). Then, when you deploy the workload with the pods you actually need, "dummy" pods are evicted so your workload pods start rapidly.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter `NodePool` as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.

## Deploy

Let's start by deploying the "dummy" workload:

```sh
kubectl apply -f dummy-workload.yaml
```

After waiting for approximately two minutes, notice how Karpenter will provision the machine(s) needed to run the "dummy" workload:

```sh
> kubectl get nodeclaims
NAME            TYPE          ZONE         NODE                          READY   AGE
default-66hfd   m6g.xlarge    us-east-1b   ip-10-0-25-181.ec2.internal   True    7m20s
default-lgmtl   m6g.xlarge    us-east-1b   ip-10-0-29-137.ec2.internal   True    7m20s
```

And the "dummy" pods are now running to reserve this capacity:

```sh
> kubectl get pods                                                                                                             7s
NAME                            READY   STATUS    RESTARTS   AGE
dummy-workload-b48bcd44-f24ng   1/1     Running   0          7m8s
dummy-workload-b48bcd44-fghws   1/1     Running   0          7m8s
```

## Results

When you deploy the actual workload (for example, a data pipeline), the dummy pods are evicted. So, let's deploy the following workload to test it:

```sh
kubectl apply -f workload.yaml
```

Notice how your new pods are running within seconds, and some "dummy" pods are "Pending":

```sh
> kubectl get pods
NAME                            READY   STATUS    RESTARTS   AGE
dummy-workload-b48bcd44-p7htz   0/1     Pending   0          13s
dummy-workload-b48bcd44-z76nf   0/1     Pending   0          13s
workload-6db87b48b4-28sxx       1/1     Running   0          74s
workload-6db87b48b4-9vmr8       1/1     Running   0          13s
workload-6db87b48b4-cs2fs       1/1     Running   0          74s
workload-6db87b48b4-dbk79       1/1     Running   0          13s
workload-6db87b48b4-gnhb6       1/1     Running   0          52s
workload-6db87b48b4-h9bfc       1/1     Running   0          33s
workload-6db87b48b4-hmkrx       1/1     Running   0          74s
workload-6db87b48b4-kpx5m       1/1     Running   0          33s
workload-6db87b48b4-n77fr       1/1     Running   0          74s
workload-6db87b48b4-nvf55       1/1     Running   0          74s
workload-6db87b48b4-tdpfh       1/1     Running   0          74s
workload-6db87b48b4-xx9kx       1/1     Running   0          74s
workload-6db87b48b4-z2g7n       1/1     Running   0          52s
workload-6db87b48b4-zcnbk       1/1     Running   0          74s
```

After waiting for approximately two minutes, you'll get the overprovision capacity and see all pods running:

```sh
> kubectl get nodeclaims                                                                            
NAME            TYPE          ZONE         NODE                          READY   AGE
default-66hfd   m6g.xlarge    us-east-1b   ip-10-0-25-181.ec2.internal   True    11m
default-lgmtl   m6g.xlarge    us-east-1b   ip-10-0-29-137.ec2.internal   True    11m
default-nzg92   m6g.xlarge    us-east-1c   ip-10-0-44-194.ec2.internal   True    57s
default-xrvmt   m6g.xlarge    us-east-1c   ip-10-0-34-140.ec2.internal   True    57s
```

The new machine is there because some "dummy" pods were pending and they exist to reserve capacity. If you think you won't need those "dummy" pods while your workload is running, you can reduce the "dummy" deployment replicas to 0, and Karpenter consolidation will kick in to remove unnecessary machines.

```sh
> kubectl scale deployment dummy-workload --replicas 0
deployment.apps/dummy-workload scaled
> kubectl get nodeclaims
NAME            TYPE         ZONE         NODE                          READY   AGE
default-nzg92   m6g.xlarge   us-east-1c   ip-10-0-44-194.ec2.internal   True    2m16s
default-xrvmt   m6g.xlarge   us-east-1c   ip-10-0-34-140.ec2.internal   True    2m16s
```

## Cleanup

To remove all objects created, run the following commands:

```sh
kubectl delete -f .
```
