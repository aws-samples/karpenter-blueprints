# Karpenter Blueprint: Using NodeOverlays

## Purpose

[NodeOverlays](https://karpenter.sh/docs/concepts/nodeoverlays/) are a Karpenter feature (currently in alpha) that allows you to inject alternative instance type information into Karpenter's scheduling simulation. This enables fine-tuning of instance pricing and adding extended resources to instance types that Karpenter considers during its decision-making process.

NodeOverlays work by modifying the instance type information that Karpenter uses during its scheduling simulation. When Karpenter evaluates which instance types can satisfy pending pod requirements, it applies any matching NodeOverlays to adjust pricing information or add extended resources before making provisioning decisions.

There are two primary use cases for NodeOverlays:

1. **Price adjustments**: Influence Karpenter's instance type selection by adjusting the perceived price of certain instance types. This is useful for prioritizing newer generation instances, accounting for savings plans, or reflecting licensing costs.

2. **Extended resources**: Add custom resources to instance types that Karpenter should consider during scheduling. This is particularly useful for GPU slicing scenarios where you want Karpenter to understand that a single GPU can serve multiple workloads.

This blueprint demonstrates both use cases with practical examples.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter `EC2NodeClass` and `NodePool` as that's the one we'll reference in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.

**NOTE:** NodeOverlays are currently in alpha (`v1alpha1`) and the API may change in future versions.

## Enable NodeOverlay Feature Gate

NodeOverlays require enabling the `NodeOverlay` feature gate in Karpenter. Update your Karpenter deployment to include the feature gate:

```sh
helm registry logout public.ecr.aws
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --set "settings.featureGates.nodeOverlay=true" \
  --reuse-values
```

Alternatively, if you're using the Terraform template from this repository, you can add the feature gate to the Karpenter Helm values.

Verify the feature gate is enabled by checking the Karpenter deployment configuration:

```sh
kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_GATES")].value}'
```

You should see `NodeOverlay=true` in the output.

---

## Scenario 1: Prioritizing Latest Generation Instances

### Overview

When you have multiple instance generations available (e.g., generation 6, 7, and 8), you might want Karpenter to prefer the latest generation for better price-performance. By default, Karpenter selects instances based on price, but newer generations often provide better value even at similar or slightly higher prices.

Using NodeOverlays, you can adjust the perceived price of older generation instances to make newer generations more attractive to Karpenter's scheduling algorithm. By using the `karpenter.k8s.aws/instance-generation` label, you can apply this preference across all instance families (c, m, r, etc.) without needing to specify each one individually.

### How It Works

When you apply a `priceAdjustment` to instance types via NodeOverlay, Karpenter adjusts its internal price calculations before making provisioning decisions:

- **For On-Demand instances**: Karpenter uses the [`lowest-price` allocation strategy](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-fleet-allocation-strategy.html#ec2-fleet-allocation-use-cases) by default. With NodeOverlay price adjustments, the perceived prices change, effectively creating a [`prioritized` allocation strategy](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-fleet-allocation-strategy.html#ec2-fleet-allocation-use-cases) where instances with lower adjusted prices are preferred.

- **For Spot instances**: When NodeOverlay price adjustments are applied, Karpenter switches from the default [`price-capacity-optimized`](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-fleet-allocation-strategy.html#spot-fleet-price-capacity-optimized) allocation strategy to [`capacity-optimized-prioritized`](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-fleet-allocation-strategy.html#spot-fleet-capacity-optimized-prioritized). The custom pricing from NodeOverlay is passed to the EC2 CreateFleet API as priorities. However, note that priorities in `capacity-optimized-prioritized` are relative (not weighted), so the difference between priority values matters less than their relative ordering. EC2 will still prioritize capacity availability to reduce interruption risk, which may override your price preferences in some cases.

For this reason, we'll use On-Demand instances in this example to demonstrate deterministic behavior based on price adjustments.

### Deploy

**NOTE:** This scenario assumes your `default` NodePool is configured to use generation 5 and above (i.e., `karpenter.k8s.aws/instance-generation` with operator `Gt` and value `"4"`). If your NodePool includes generation 4 or below, you'll need to add additional NodeOverlays to penalize those generations as well.

First, let's create NodeOverlays that penalize older generations. Generation 5 instances get a 45% price increase, generation 6 gets 30%, generation 7 gets 15%, and generation 8 (the latest) has no penalty:

```yaml
# Penalize generation 5 instances (e.g., c5, m5, r5)
apiVersion: karpenter.sh/v1alpha1
kind: NodeOverlay
metadata:
  name: penalize-gen5
spec:
  weight: 10
  requirements:
    - key: karpenter.k8s.aws/instance-generation
      operator: In
      values: ["5"]
  priceAdjustment: "+45%"
---
# Penalize generation 6 instances (e.g., c6g, m6i, r6g)
apiVersion: karpenter.sh/v1alpha1
kind: NodeOverlay
metadata:
  name: penalize-gen6
spec:
  weight: 10
  requirements:
    - key: karpenter.k8s.aws/instance-generation
      operator: In
      values: ["6"]
  priceAdjustment: "+30%"
---
# Penalize generation 7 instances (e.g., c7g, m7i, r7g)
apiVersion: karpenter.sh/v1alpha1
kind: NodeOverlay
metadata:
  name: penalize-gen7
spec:
  weight: 10
  requirements:
    - key: karpenter.k8s.aws/instance-generation
      operator: In
      values: ["7"]
  priceAdjustment: "+15%"
# Generation 8 instances (e.g., c8g, m8g) will have no penalty,
# making them the preferred choice when available.
```

```sh
kubectl apply -f node-overlay-generation.yaml
```

Now deploy a sample workload that will trigger Karpenter to provision a node:

```sh
kubectl apply -f workload-generation.yaml
```

### Results

Wait about one minute for Karpenter to provision the node:

```sh
kubectl get nodeclaims
```

You should see a generation 8 instance (like `c8g`, `m8g`) being launched instead of older generations:

```console
NAME            TYPE          ZONE         NODE                                        READY   AGE
default-xxxxx   c8g.xlarge    eu-west-1b   ip-10-0-xx-xx.eu-west-1.compute.internal    True    45s
```

You can verify the NodeOverlays are applied by checking their status:

```sh
kubectl get nodeoverlay
```

Look for the `Ready=True` condition indicating the overlays are successfully applied.

### Cleanup Scenario 1

```sh
kubectl delete -f workload-generation.yaml
kubectl delete -f node-overlay-generation.yaml
```

---

## Scenario 2: GPU Time-Slicing with NodeOverlay

### Overview

Many inference and AI/ML workloads don't require an entire GPU. [NVIDIA Time-Slicing](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html) allows multiple workloads to share a single GPU by rapidly switching context between containers, giving each a "slice" of processing time.

Bottlerocket has built-in support for GPU time-slicing through its NVIDIA device plugin settings. When configured with `replicas = 4`, a node with 1 physical GPU will advertise `nvidia.com/gpu: 4`, allowing 4 pods to share that GPU.

### Why NodeOverlay?

When time-slicing is configured on nodes, Karpenter doesn't know about the increased capacity until the node exists. This can lead to suboptimal provisioning decisions:

- Without NodeOverlay: Karpenter sees 4 pending pods requesting `nvidia.com/gpu: 1` each and might provision 4 separate GPU instances
- With NodeOverlay: Karpenter understands that 1 GPU instance can serve 4 pods, so it provisions just 1 instance

NodeOverlay bridges this gap by informing Karpenter about the effective GPU capacity BEFORE provisioning, enabling:
- Better initial node selection (right-sizing from the start)
- Smarter consolidation decisions
- More accurate cost calculations

### How It Works

This scenario combines two configurations:

1. **EC2NodeClass with time-slicing**: Configures Bottlerocket to enable GPU time-slicing with 4 replicas per GPU
2. **NodeOverlay**: Tells Karpenter that GPU instances have 4x the GPU capacity

The EC2NodeClass uses Bottlerocket's userData to configure time-slicing:

```yaml
userData: |
  [settings.kubelet-device-plugins.nvidia]
  device-sharing-strategy = "time-slicing"
  [settings.kubelet-device-plugins.nvidia.time-slicing]
  replicas = 4
  rename-by-default = false
```

The `rename-by-default = false` setting keeps the resource name as `nvidia.com/gpu` (instead of renaming to `nvidia.com/gpu.shared`), so pods can request `nvidia.com/gpu: 1` as usual.

The NodeOverlay tells Karpenter about this capacity:

```yaml
apiVersion: karpenter.sh/v1alpha1
kind: NodeOverlay
metadata:
  name: gpu-slices-1gpu
spec:
  weight: 10
  requirements:
    - key: karpenter.k8s.aws/instance-gpu-count
      operator: In
      values: ["1"]
    - key: karpenter.k8s.aws/instance-gpu-manufacturer
      operator: In
      values: ["nvidia"]
  capacity:
    nvidia.com/gpu: 4
```

### Deploy

Before deploying, you need to replace the placeholders in the EC2NodeClass with your cluster-specific values.

If you're using the Terraform template provided in this repo, run the following commands:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> **NOTE**: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). `KARPENTER_NODE_IAM_ROLE_NAME` is the IAM role name that Karpenter nodes will use.

Then replace the placeholders and apply the EC2NodeClass:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" gpu-nodeclass.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" gpu-nodeclass.yaml
kubectl apply -f gpu-nodeclass.yaml
kubectl apply -f gpu-nodepool.yaml
```

Now apply the NodeOverlay that informs Karpenter about the GPU capacity:

```sh
kubectl apply -f node-overlay-gpu-slices.yaml
```

### Test 1: Deploy 4 Replicas

Deploy 4 replicas, each requesting 1 GPU (which is actually 1/4 of a physical GPU with time-slicing):

```sh
kubectl apply -f workload-gpu-slices.yaml
```

Wait for Karpenter to provision the node (GPU instances may take 2-3 minutes):

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-slices
```

You should see a single GPU instance launched:

```console
NAME              TYPE           ZONE         NODE                                        READY   AGE
gpu-slices-xxx    g4dn.xlarge    eu-west-1a   ip-10-0-xx-xx.eu-west-1.compute.internal    True    2m
```

Verify the node has 4 GPU resources advertised (due to time-slicing):

```sh
kubectl get nodes -l karpenter.sh/nodepool=gpu-slices -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'
```

You should see `4` (not `1`), confirming time-slicing is working.

Check that all 4 pods are running on this single node:

```sh
kubectl get pods -l app=workload-gpu-slices -o wide
```

### Test 2: Scale to 8 Replicas

```sh
kubectl scale deployment workload-gpu-slices --replicas=8
```

Check the nodes:

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-slices
```

Karpenter should provision a second GPU instance to handle the additional 4 pods:

```console
NAME              TYPE           ZONE         NODE                                        READY   AGE
gpu-slices-xxx    g4dn.xlarge    eu-west-1a   ip-10-0-xx-xx.eu-west-1.compute.internal    True    5m
gpu-slices-yyy    g4dn.xlarge    eu-west-1b   ip-10-0-yy-yy.eu-west-1.compute.internal    True    30s
```

### Test 3: Scale to 17 Replicas

```sh
kubectl scale deployment workload-gpu-slices --replicas=17
```

With 17 replicas and 4 slices per GPU, Karpenter needs at least 5 GPUs worth of capacity (17/4 = 4.25, rounded up to 5).

Check the nodes:

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-slices
```

You should see 5 GPU instances provisioned.

### Cleanup Scenario 2

```sh
kubectl delete -f workload-gpu-slices.yaml
kubectl delete -f node-overlay-gpu-slices.yaml
kubectl delete -f gpu-nodepool.yaml
kubectl delete -f gpu-nodeclass.yaml
```

---

## Scenario 3: Targeting Specific NodePools

### Overview

By default, NodeOverlays apply to all instance types that match their requirements across your entire cluster. However, in multi-tenant environments or clusters with multiple NodePools serving different purposes, you may want to apply a NodeOverlay to only specific workloads or NodePools without affecting others.

NodeOverlays support targeting using requirements that work exactly like NodePool requirements. You can use any well-known label or Karpenter-specific label to scope where your overlay applies, including targeting specific NodePools, capacity types, architectures, zones, or any other node attribute.

### Use Case

In multi-tenant clusters where different teams manage their own NodePools, you may want to apply specific instance selection preferences to your team's workloads without affecting other teams' configurations. Without proper targeting, applying a NodeOverlay would affect the entire cluster, potentially disrupting other teams' carefully tuned configurations.

NodeOverlay requirements work exactly like NodePool requirements, allowing you to target by NodePool name (`karpenter.sh/nodepool`), capacity type (`karpenter.sh/capacity-type`), zone (`topology.kubernetes.io/zone`), instance generation (`karpenter.k8s.aws/instance-generation`), or any other well-known label.

### Deploy

First, create a dedicated NodePool that you want to target. This example creates a NodePool called `team-alpha`:

```sh
kubectl apply -f nodepool-targeted.yaml
```

Now create NodeOverlays that target ONLY the `team-alpha` NodePool to prefer the latest generation instances. In this example, we use the `karpenter.sh/nodepool` requirement to target a specific NodePool:

```sh
kubectl apply -f node-overlay-targeted.yaml
```

Here's the key section that enables targeting:

```yaml
apiVersion: karpenter.sh/v1alpha1
kind: NodeOverlay
metadata:
  name: team-alpha-prefer-latest-gen
spec:
  weight: 10
  requirements:
    # Target a specific NodePool by name
    - key: karpenter.sh/nodepool
      operator: In
      values: ["team-alpha"]
    # Apply the overlay to generation 5 instances
    - key: karpenter.k8s.aws/instance-generation
      operator: In
      values: ["5"]
  # Penalize generation 5 by 45% to prefer newer generations
  priceAdjustment: "+45%"
```

The requirements work exactly like NodePool requirements. You can use `karpenter.sh/nodepool` to target by NodePool name, or use any other requirement key like `karpenter.sh/capacity-type`, `topology.kubernetes.io/zone`, or custom labels to scope your overlay.

### Testing

Deploy a workload that targets the `team-alpha` NodePool:

```sh
kubectl apply -f workload-targeted.yaml
```

Wait for Karpenter to provision a node:

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=team-alpha
```

You should see a newer generation instance (generation 7 or 8) provisioned for the `team-alpha` NodePool:

```console
NAME            TYPE          ZONE         NODE                                        READY   AGE
team-alpha-xxx  c7i.xlarge    eu-west-1a   ip-10-0-xx-xx.eu-west-1.compute.internal    True    45s
```

Verify the generation:

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=team-alpha -o jsonpath='{.items[*].metadata.labels.karpenter\.k8s\.aws/instance-generation}'
```

You should see `7` or `8`, confirming the NodeOverlay preference is working.

Now verify that the `default` NodePool is NOT affected by these overlays. Deploy a workload to the default NodePool:

```sh
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workload-default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: workload-default
  template:
    metadata:
      labels:
        app: workload-default
    spec:
      nodeSelector:
        karpenter.sh/nodepool: default
      containers:
      - name: pause
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.9
        resources:
          requests:
            cpu: 1
            memory: 1Gi
      terminationGracePeriodSeconds: 0
EOF
```

Check what generation was selected for the default NodePool:

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=default -o jsonpath='{.items[*].metadata.labels.karpenter\.k8s\.aws/instance-generation}'
```

The default NodePool should select instances based on pure price optimization (likely generation 5 or 6 depending on current pricing), proving that the NodeOverlays only affected the `team-alpha` NodePool.

### Results

This demonstrates that:

1. NodeOverlays can be scoped using requirements, just like NodePools
2. You can target specific NodePools, capacity types, zones, architectures, or any other node attribute
3. Multiple NodePools can coexist with different NodeOverlay configurations
4. Teams in multi-tenant clusters can independently tune their workload behavior without affecting others

### Cleanup Scenario 3

```sh
kubectl delete -f workload-targeted.yaml
kubectl delete deployment workload-default
kubectl delete -f node-overlay-targeted.yaml
kubectl delete -f nodepool-targeted.yaml
```

---

## Key Takeaways

1. **NodeOverlay informs Karpenter's scheduling simulation**: It helps Karpenter make better provisioning decisions by understanding capacity before nodes exist. The actual node configuration must match what NodeOverlay declares.

2. **NodeOverlays can be targeted using requirements**: Use any requirement key available in NodePools (like `karpenter.sh/nodepool`, `karpenter.sh/capacity-type`, `topology.kubernetes.io/zone`, etc.) to scope overlays to specific workloads or NodePools, enabling targeted configuration in multi-tenant clusters without affecting other teams.

3. **Price adjustments work best with On-Demand**: For Spot instances, EC2's capacity-optimized strategy may override your price preferences.

4. **GPU time-slicing requires both NodeOverlay and node configuration**: NodeOverlay tells Karpenter about the capacity, while the EC2NodeClass userData configures actual time-slicing on Bottlerocket nodes.

5. **Bottlerocket simplifies GPU time-slicing**: Unlike other AMIs that require the full NVIDIA GPU Operator, Bottlerocket has built-in support for time-slicing via userData settings.

6. **NodeOverlays integrate with consolidation**: Price and capacity changes affect consolidation decisions, potentially triggering node replacements when configurations change.

## Full Cleanup

```sh
kubectl delete -f .
```
