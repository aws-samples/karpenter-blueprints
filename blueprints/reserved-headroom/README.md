# Reserved Headroom (DaemonSet) Blueprint

## Purpose
You might want to ensure there is always **reserved resources capacity on each node** for spiky or bursty workloads. Unlike the classic overprovisioning pattern that warms up new nodes by running low-priority pods, reserved headroom guarantees that a slice of CPU and memory remains available **within existing nodes**. This ensures burst-critical workloads can start immediately without waiting for new nodes or being throttled by full utilization.

The headroom DaemonSet works by running lightweight `pause` pods that **request** CPU and memory on each node without actually consuming them. 
This means the Kubernetes scheduler marks those resources as “in use,” preventing normal workloads from filling the node completely. 
When a burst-critical workload arrives, it can immediately preempt the headroom pod and gain access to that reserved slice of CPU/memory. 
In practice, this ensures that resources stay free for spiky workloads without wasting capacity on actual resource-consuming pods.

- **Overprovisioning**: Warm up cluster-level capacity by forcing scale-out.
- **Reserved Headroom**: Reserve node-level capacity so workloads already placed on a node can burst quickly.

## Requirements
* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter `NodePool` as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.

## Deploy
First, create the PriorityClasses:

```bash
kubectl apply -f priorityclasses.yaml
```

### PriorityClasses
Two classes are used:
- **headroom-high**: used by the DaemonSet to reserve capacity.
- **burst-critical**: slightly higher value, used by spiky workloads that can preempt the DaemonSet when needed.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: headroom-high
value: 900000000
preemptionPolicy: PreemptLowerPriority
globalDefault: false
description: "High priority for DaemonSet reserving per-node headroom. Preemptible by burst-critical."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: burst-critical
value: 1000000000
preemptionPolicy: PreemptLowerPriority
globalDefault: false
description: "Workloads with this priority can preempt headroom-high pods to consume reserved capacity instantly."
```

### DaemonSet
Deploy the DaemonSet that reserves CPU and memory per node:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: headroom-reserver
  namespace: default
  labels:
    app: headroom-reserver
spec:
  selector:
    matchLabels:
      app: headroom-reserver
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: headroom-reserver
    spec:
      priorityClassName: headroom-high
      terminationGracePeriodSeconds: 0
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
```

Apply it:
```bash
kubectl apply -f daemonset.yaml
```

### Example Bursty Workload
Now deploy a workload with the `burst-critical` PriorityClass:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-burst
  namespace: default
  labels:
    app: demo-burst
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-burst
  template:
    metadata:
      labels:
        app: demo-burst
    spec:
      priorityClassName: burst-critical       # tolerate common taints so the scheduler can place this
      containers:
        - name: cpu-burn
          image: public.ecr.aws/amazonlinux/amazonlinux:2
          command: ["/bin/sh","-c"]
          args: ["while true; do sha1sum /dev/zero | head -c 1000000 > /dev/null; sleep 0.5; done"]
          resources:
            requests:
              cpu: "200m"
              memory: "128Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"

```

Apply it:
```bash
kubectl apply -f spiky-workload.yaml
```

## Results
When the bursty workload is scheduled, the scheduler will preempt the `headroom-reserver` DaemonSet pod on that node, instantly freeing the reserved resources. This ensures:
- Regular workloads cannot consume the reserved slice.
- Burst-critical workloads gain immediate access to CPU/memory without scale-out delays.

Check events to observe preemption:
```bash
kubectl get events --sort-by=.lastTimestamp | grep -i preempt
```

Check pods:
```bash
kubectl get pods -n default
```

You should see that DaemonSet pods get evicted as `demo-burst` pods scale.

## Cleanup
To remove all created resources:

```bash
kubectl delete -f .
```
