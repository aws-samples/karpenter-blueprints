# Karpenter Blueprint: Size kubelet settings per instance type with CEL expressions

## Purpose

Kubelet settings like `maxPods`, `kubeReserved`, and `systemReserved` depend on the size of the node. A static value in an `EC2NodeClass` applies to every instance Karpenter launches from it, so it's wrong for some of them: `systemReserved.cpu: 100m` is plenty on a 2-vCPU node and too little on a 32-vCPU one. Teams usually work around this by splitting one NodePool into several, each with its own `EC2NodeClass` and a narrow instance-size range. That trades away the flexibility that makes Karpenter efficient.

Karpenter [v1.15.0](https://github.com/aws/karpenter-provider-aws/releases/tag/v1.15.0) lets `maxPods`, `kubeReserved`, and `systemReserved` take a [CEL](https://cel.dev/) expression instead of a fixed value. Karpenter evaluates the expression for each instance type, uses the result in its scheduling simulation, and writes the same result into the node's kubelet configuration. One `EC2NodeClass` can then cover the full range of instance sizes.

This blueprint uses one `EC2NodeClass` to:

- Set `maxPods` to the same limits [EKS managed node groups use with prefix delegation](https://docs.aws.amazon.com/eks/latest/userguide/create-managed-node-group.html) (110 pods below 30 vCPUs, 250 above). The repo's cluster template turns prefix delegation on, but without this setting Karpenter still uses the ENI-limited pod count (29 on a 2-vCPU `.large`).
- Scale `kubeReserved.memory` with the `maxPods` value resolved for that instance type.
- Scale `systemReserved` CPU and memory with the instance's vCPUs and memory.

It then launches a 2-vCPU and a 32-vCPU node from the same NodePool and shows how the same expressions resolve on each.

> [!NOTE]
> Kubelet expressions are an **alpha** feature behind the `NodeClassCEL` AWS feature gate. The API may change in future versions.

## Requirements

- An EKS cluster with self-managed Karpenter **v1.15.0 or later**. The repo's `cluster/terraform/` template installs a compatible version.
- The `NodeClassCEL` AWS feature gate turned on (see the next section).
- The `CLUSTER_NAME` and `KARPENTER_NODE_IAM_ROLE_NAME` environment variables set. If you used the repo's Terraform template, see the main [README](../../README.md) for how to export them.
- The VPC CNI with prefix delegation turned on, if you keep the `maxPods` expression as written. The repo's cluster template already turns it on. Without prefix delegation, nodes don't have enough IP addresses for 110 pods; see [Adapting the expressions](#adapting-the-expressions).

> **EKS Auto Mode is not supported.** Auto Mode's `NodeClass` (`eks.amazonaws.com/v1`) doesn't expose kubelet settings, so this blueprint only applies to self-managed Karpenter.

## Turn on the NodeClassCEL feature gate

`NodeClassCEL` is an AWS-specific gate, so it lives under `settings.awsFeatureGates` rather than `settings.featureGates`:

```sh
helm registry logout public.ecr.aws
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --version 1.15.1 \
  --reuse-values \
  --set "settings.awsFeatureGates.nodeClassCEL=true"
```

If you manage Karpenter with the Terraform template in this repo, add the same setting to the Helm values in `cluster/terraform/karpenter.tf` instead, so the next `terraform apply` doesn't remove it:

```yaml
settings:
  awsFeatureGates:
    nodeClassCEL: true
```

Verify the gate is on:

```sh
kubectl -n karpenter get deployment karpenter \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_FEATURE_GATES")].value}'
```

The output should include `NodeClassCEL=true`.

## Deploy

Substitute your cluster name and node IAM role name, then apply the `EC2NodeClass` and `NodePool`:

```sh
sed -e "s|<<CLUSTER_NAME>>|$CLUSTER_NAME|g" \
    -e "s|<<KARPENTER_NODE_IAM_ROLE_NAME>>|$KARPENTER_NODE_IAM_ROLE_NAME|g" \
    kubelet-cel-sizing.yaml | kubectl apply -f -
```

Here's the kubelet section of the `EC2NodeClass`:

```yaml
  kubelet:
    maxPods: "min(vcpus < 30 ? 110 : 250, default_enis * (ips_per_eni - 1) * 16 + 2)"
    kubeReserved:
      cpu: "60 + vcpus * 5"
      memory: "11 * max_pods + 255"
    systemReserved:
      cpu: "max(100, vcpus * 10)"
      memory: "max(100, memory_mib / 64)"
```

- `maxPods` picks 110 or 250 by vCPU count. The `min()` keeps the result within what the instance's ENI prefixes can address (each `/28` prefix holds 16 addresses), so the expression stays safe if you widen the NodePool to instance types with few ENIs.
- `kubeReserved.memory` is the EKS AMI formula. `max_pods` is the `maxPods` value Karpenter just resolved for this instance type, so memory reserved for the kubelet grows with pod density. This matters on AL2023: when you don't set it, Karpenter sizes the default from the ENI-limited pod count, even if `maxPods` is higher.
- `kubeReserved.cpu` and `systemReserved` grow with vCPUs and memory, with a floor for small instances.

Expression results are plain numbers. Karpenter adds the unit for you: CPU results are millicores, rounded up to a multiple of `10m`, and memory results are MiB, rounded up to a multiple of `16Mi`. See [Result units and rounding](https://karpenter.sh/docs/concepts/nodeclasses/#dynamic-kubelet-configuration-via-expressions) for the full list of variables, functions, and units.

> [!WARNING]
> A value that parses as a Kubernetes quantity is used as-is, not as an expression. `cpu: "100"` reserves 100 *cores*, not 100 millicores. Use a quantity with a unit (`100m`) for static values.

Check that Karpenter accepted the expressions:

```sh
kubectl get ec2nodeclass kubelet-cel-sizing \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
```

Both `ValidationSucceeded` and `Ready` should be `True`.

Now deploy the sample workload. It runs two single-replica Deployments in the same NodePool. One pins its pod to a 2-vCPU instance and the other to a 32-vCPU instance, using the `karpenter.k8s.aws/instance-cpu` label:

```sh
kubectl apply -f workload.yaml
```

## Results

Wait for both nodes to become `Ready`:

```sh
kubectl get nodes -l karpenter.sh/nodepool=kubelet-cel-sizing \
  -L node.kubernetes.io/instance-type,karpenter.k8s.aws/instance-cpu,karpenter.k8s.aws/instance-memory
```

Then compare the pod capacity and allocatable resources Kubernetes reports for each node:

```sh
kubectl get nodes -l karpenter.sh/nodepool=kubelet-cel-sizing \
  -o custom-columns='NAME:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,PODS:.status.capacity.pods,CPU:.status.capacity.cpu,ALLOC_CPU:.status.allocatable.cpu,MEM:.status.capacity.memory,ALLOC_MEM:.status.allocatable.memory'
```

The expressions resolve to these values. The memory rows assume both nodes are `c`-family instances (4 GiB and 64 GiB). Karpenter picks instance types by price and availability, so if you get an `m` or `r` instance, `systemReserved.memory` will be higher.

| Setting | 2 vCPU, 4 GiB | 32 vCPU, 64 GiB |
| --- | --- | --- |
| `maxPods` | `110` | `250` |
| `kubeReserved.cpu` | `70m` | `220m` |
| `kubeReserved.memory` | `1472Mi` (1465, rounded up) | `3008Mi` (3005, rounded up) |
| `systemReserved.cpu` | `100m` | `320m` |
| `systemReserved.memory` | `112Mi` (100, rounded up) | `1024Mi` |
| Total reserved CPU (capacity minus allocatable) | `170m` | `540m` |

`PODS` should match `maxPods`, and `CPU` minus `ALLOC_CPU` should match the total reserved CPU. For memory, the difference between `MEM` and `ALLOC_MEM` is the sum of both reservations plus the kubelet's hard eviction threshold (`100Mi` by default).

With a single static `EC2NodeClass`, you'd have had to choose one set of values for both nodes, or split the NodePool by instance size.

### What happens if an expression is wrong

The API server doesn't reject expressions. Karpenter validates them and reports problems on the `EC2NodeClass` status, then marks it `NotReady` so it launches no nodes until you fix it. For example, a typo in a variable name (`vcpu` instead of `vcpus`):

```yaml
  kubelet:
    maxPods: "vcpu * 8"
```

sets `ValidationSucceeded=False` with reason `KubeletExpressionInvalid`:

```sh
kubectl get ec2nodeclass <name> \
  -o jsonpath='{.status.conditions[?(@.type=="ValidationSucceeded")]}'
```

An expression that compiles but fails for some instance types, like a subtraction that goes negative on small instances, reports `KubeletExpressionEvaluationFailed` instead. If the feature gate is off, a NodeClass with expressions reports `KubeletExpressionsDisabled`.

Validation only checks that expressions compile and evaluate. It can't tell you whether the values make sense for your workloads, so test new expressions in a non-production NodePool before you roll them out.

## Adapting the expressions

- **No prefix delegation.** Use the ENI-limited formula and cap it: `maxPods: "min(110, default_enis * (ips_per_eni - 1) + 2)"`.
- **Small instances with many pods.** 110 pods on a 2-vCPU, 4 GiB instance reserves about 1.5 GiB for the kubelet. If your pods are small but your nodes are too, scale density with size instead, for example `maxPods: "min(110, vcpus * 16)"`.
- **Per-instance-type overrides.** `instance_type` is available as a string for conditionals, for example `maxPods: "instance_type == \"m5.large\" ? 58 : min(110, max_pods)"`. Keep these rare, since a long list of special cases is harder to review than a separate NodePool.

## Automated verification

`test.sh` runs two scenarios:

- **Scenario 1** applies the blueprint, waits for a 2-vCPU and a 32-vCPU node, and checks each node against the values the expressions should produce: `capacity.pods` matches `maxPods`, reserved CPU (capacity minus allocatable) exactly matches `kubeReserved.cpu + systemReserved.cpu`, and reserved memory is at least `kubeReserved.memory + systemReserved.memory`.
- **Scenario 2** applies an `EC2NodeClass` with an invalid expression and checks that it reports `KubeletExpressionInvalid` and doesn't become `Ready`. It doesn't launch any nodes.

```sh
./test.sh            # both scenarios
./test.sh scenario2  # only the validation check
```

## Cleanup

```sh
kubectl delete -f workload.yaml
kubectl delete nodepool kubelet-cel-sizing
kubectl delete ec2nodeclass kubelet-cel-sizing
```

## References

- Karpenter release notes: [v1.15.0](https://github.com/aws/karpenter-provider-aws/releases/tag/v1.15.0) and feature PR [karpenter-provider-aws#9326](https://github.com/aws/karpenter-provider-aws/pull/9326)
- Karpenter docs: [Dynamic Kubelet Configuration via Expressions](https://karpenter.sh/docs/concepts/nodeclasses/#dynamic-kubelet-configuration-via-expressions)
- Design RFC: [CEL expressions in kubelet config fields](https://github.com/aws/karpenter-provider-aws/pull/9342)
- EKS best practices: [Prefix mode for Linux](https://docs.aws.amazon.com/eks/latest/best-practices/prefix-mode-linux.html)
- EKS user guide: [maxPods limits for managed node groups](https://docs.aws.amazon.com/eks/latest/userguide/create-managed-node-group.html)
