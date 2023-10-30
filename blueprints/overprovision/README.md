# Karpenter Blueprint: Overprovision capacity in advanced to increase responsiveness

## Purpose
Let's say you have a data pipeline process that knows it will need to have the capacity to launch 100 pods at the same time. To reduce the initiation time, you could overprovision capacity in advanced to increase responsiveness so when the data pipeline launches the pods, the capacity is already there. 

To achieve this, you deploy a "dummy" workload with a low [PriorityClass](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/#priorityclass) to reserve capacity (to make Karpenter launch nodes). Then, when you deploy the workload with the pods you actually need, "dummy" pods are evicted to make rapidly start the pods you need for your workload.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter provisioner as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default Provisioner"](../../README.md) section from this repository.

## Deploy
Let's start by deploying the "dummy" workload:

```
kubectl apply -f dummy-workload.yaml
```

After waiting for around two minutes, notice how Karpenter will provision the machine(s) needed to run the "dummy" workload:

```
> kubectl get machines
NAME            TYPE          ZONE         NODE                                       READY   AGE
default-kpj7k   c6i.2xlarge   eu-west-1b   ip-10-0-73-34.eu-west-1.compute.internal   True    57s
```

And the "dummy" pods are now running simply to reserve this capacity:

```
> kubectl get pods                                                                                                             7s
NAME                             READY   STATUS    RESTARTS   AGE
dummy-workload-6bf87d68f-2ftbq   1/1     Running   0          53s
dummy-workload-6bf87d68f-8pnp8   1/1     Running   0          53s
dummy-workload-6bf87d68f-ctlvc   1/1     Running   0          53s
dummy-workload-6bf87d68f-fznv6   1/1     Running   0          53s
dummy-workload-6bf87d68f-hp4qs   1/1     Running   0          53s
dummy-workload-6bf87d68f-pwtp9   1/1     Running   0          53s
dummy-workload-6bf87d68f-rg7tj   1/1     Running   0          53s
dummy-workload-6bf87d68f-t7bqz   1/1     Running   0          53s
dummy-workload-6bf87d68f-xwln7   1/1     Running   0          53s
dummy-workload-6bf87d68f-zmhk8   1/1     Running   0          53s
```

## Results
Now, when you deploy the actual workload you need  to do some work (such as a data pipeline process), the "dummy" pods are going to be evicted. So, let's deploy the following workload to test it:

```
kubectl apply -f workload.yaml
```

Notice how your new pods are almost immediately running, and some of the "dummy" pods are "Pending":

```
> kubectl get pods
NAME                             READY   STATUS    RESTARTS   AGE
dummy-workload-6bf87d68f-2ftbq   1/1     Running   0          11m
dummy-workload-6bf87d68f-6bq4v   0/1     Pending   0          15s
dummy-workload-6bf87d68f-8nkp8   0/1     Pending   0          14s
dummy-workload-6bf87d68f-cchqx   0/1     Pending   0          15s
dummy-workload-6bf87d68f-fznv6   1/1     Running   0          11m
dummy-workload-6bf87d68f-hp4qs   1/1     Running   0          11m
dummy-workload-6bf87d68f-r69g6   0/1     Pending   0          15s
dummy-workload-6bf87d68f-rg7tj   1/1     Running   0          11m
dummy-workload-6bf87d68f-w4zk8   0/1     Pending   0          15s
dummy-workload-6bf87d68f-zmhk8   1/1     Running   0          11m
workload-679c759476-6h47j        1/1     Running   0          15s
workload-679c759476-hhjmp        1/1     Running   0          15s
workload-679c759476-jxnc2        1/1     Running   0          15s
workload-679c759476-lqv5t        1/1     Running   0          15s
workload-679c759476-n269j        1/1     Running   0          15s
workload-679c759476-nfjtp        1/1     Running   0          15s
workload-679c759476-nv7sg        1/1     Running   0          15s
workload-679c759476-p277d        1/1     Running   0          15s
workload-679c759476-qw8sk        1/1     Running   0          15s
workload-679c759476-sxjpt        1/1     Running   0          15s
```

After waiting for around two minutes, you'll see all pods running and a new machine registered:

```
> kubectl get machines                                                                                                        18s
NAME            TYPE          ZONE         NODE                                        READY   AGE
default-kpj7k   c6i.2xlarge   eu-west-1b   ip-10-0-73-34.eu-west-1.compute.internal    True    14m
default-s6dbs   m5.xlarge     eu-west-1a   ip-10-0-35-186.eu-west-1.compute.internal   True    2m8s
```

The new machine is simply there because some "dummy" pods were pending and they exist to reserve capacity. If you think you won't need those "dummy" pods while your workload is running, you can simply reduce the "dummy" deployment replicas to 0, and Karpenter consolidation will kick in to remove unnecessary machines.

```
> kubectl scale deployment dummy-workload --replicas 0
deployment.apps/dummy-workload scaled
> kubectl get machines
NAME            TYPE          ZONE         NODE                                       READY   AGE
default-kpj7k   c6i.2xlarge   eu-west-1b   ip-10-0-73-34.eu-west-1.compute.internal   True    16m
```

## Cleanup
To remove all objects created, simply run the following commands:

```
kubectl delete -f .
```