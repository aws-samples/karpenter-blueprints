# Karpenter Blueprint: Static NodePool

## Purpose

The purpose of this blueprint is to demonstrate how to maintain a fixed number of nodes running in your cluster regardless of workload demand. Setting `spec.replicas` in a NodePool tells Karpenter to maintain a node count. This blueprint walks through setting up a static node pool for GPU instances alongside configuring network interfaces (ENA or EFA) and how to configure capacity reservations or placement groups.

You might consider this when:
- You've purchased capacity via [EC2 Capacity Blocks for ML](https://aws.amazon.com/ec2/capacityblocks/) or [On-Demand Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html) and want a fixed node count
- You need a static cluster of accelerated nodes with EFA networking for distributed training

## Requirements

* A Kubernetes cluster with Karpenter installed. Karpenter v1.11+ is required for placement group and network interface configuration support. You can use the cluster we've used to test this pattern at the `cluster` folder in the root of this repository.
* The `StaticCapacity` feature gate must be enabled. This feature is in Alpha (default: `false`) since Karpenter v1.8.x. Update your Karpenter deployment to include the feature gate:

```sh
helm registry logout public.ecr.aws
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --set "settings.featureGates.staticCapacity=true" \
  --reuse-values
```

Alternatively, if you're using the Terraform template from this repository, you can add the feature gate to the Karpenter Helm values.

Verify the feature gate is enabled by checking the Karpenter deployment configuration:

```sh
kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_GATES")].value}'
```

You should see `StaticCapacity=true` in the output.

For accelerated instances, you will also need your cluster to have the required drivers and device plugins to advertise accelerators to Kubernetes. You can learn more about what is included as part of the EKS-optimized accelerated AMIs [here](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html).

## Deploy

Before applying the manifests, set your cluster-specific variables. If you're using the Terraform template provided in this repo, run the following commands:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/docs/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role (not the ARN).

### Create the EC2NodeClass

This defines the AWS-specific config for GPU nodes in the static pool:

```sh
cat << EOF > static-nodeclass.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-static
spec:
  amiSelectorTerms:
  - alias: bottlerocket@latest
  role: "$KARPENTER_NODE_IAM_ROLE_NAME"
  networkInterfaces:
  - networkCardIndex: 0
    deviceIndex: 0
    interfaceType: "interface"
  - networkCardIndex: 0
    deviceIndex: 1
    interfaceType: "efa-only"
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: $CLUSTER_NAME
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: $CLUSTER_NAME
  instanceStorePolicy: RAID0
EOF
```

#### Network interface configuration (ENA / EFA)

You might decide to attach EFA devices for high-throughput inter-node communication (e.g. RDMA). To do this you can configure `networkInterfaces` as part of the EC2NodeClass. Two interface types are available:

- `interface` — standard ENA providing IP connectivity
- `efa-only` — EFA device for RDMA, doesn't consume an IP address

The `interface` entry handles IP networking. The `efa-only` entry attaches an EFA device for RDMA traffic. Instances with multiple network cards (e.g., p6-b200.48xlarge) need additional entries.

The configuration in the EC2NodeClass above defines that instances launched by this EC2NodeClass primary network interface is `ena` and secondary as `efa-only`.

> **NOTE**: Network interface configuration varies by instance type. Check the [EFA documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-acc-inst-types.html) and [EC2 network specifications](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-network-bandwidth.html) for your specific instance.

#### Placement groups

To specify an [EC2 placement group](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/placement-groups.html), add a `placementGroupSelector` to the EC2NodeClass.

```yaml
  placementGroupSelector:
    name: my-gpu-cluster-pg
```

You might use placement groups to co-locate compute for performance, or spread for resilience. Karpenter supports three placement group strategies:
- **Cluster** — single AZ, same network segment, best for EFA workloads
- **Partition** — up to 7 isolated partitions per AZ for fault isolation
- **Spread** — each instance on distinct hardware, max 7 per AZ per group

> **NOTE**: The placement group must already exist before applying the EC2NodeClass — Karpenter does not create placement groups. Placement group support requires Karpenter v1.11.0+. See the [Karpenter EC2NodeClass documentation](https://karpenter.sh/docs/concepts/nodeclasses/#specplacementgroupselector) for more information.

#### Capacity reservations

If using capacity via ODCRs or Capacity Blocks, add `capacityReservationSelectorTerms` to target it using id or tags:

```yaml
  capacityReservationSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
    - id: cr-123
```

Tagging your reservations at purchase time (e.g., `karpenter.sh/discovery: ${CLUSTER_NAME}`) makes them easier to manage as Karpenter can discover them automatically via tag selectors instead of requiring you to track individual reservation IDs. This is especially useful when you have multiple reservations.

To use reserved capacity in your NodePool, add `reserved` to the `karpenter.sh/capacity-type` requirement:

```yaml
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["reserved"]
```

### Create the NodePool

The NodePool maintains the static GPU node count of `g6e.8xlarge`. 

```sh
cat << EOF > static-nodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-static
spec:
  replicas: 1
  limits:
    nodes: 2
  template:
    metadata:
      labels:
        capacity-type: gpu-static
        nvidia.com/gpu.present: "true"
        vpc.amazonaws.com/efa.present: "true"
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        name: gpu-static
        kind: EC2NodeClass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["g6e.8xlarge"]
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
EOF
```

In this example, the `karpenter.sh/capacity-type` was set to `on-demand`, to use reserved capacity (ODCRs or Capacity Blocks), add `reserved` to the `karpenter.sh/capacity-type` values and check the EC2NodeClass references the reserved capacity otherwise reservations will not be used. You need to set `node.kubernetes.io/instance-type` to the reserved instance type so it matches the capacity reservation.

> **NOTE**: Adjust `replicas`, `limits.nodes`, and instance type for your setup. `limits.nodes` caps the node count during scaling or drift replacement.

To specify an AZ for static capacity based on your reservation, you can add the `topology.kubernetes.io/zone` to your NodePool:

```sh
- key: topology.kubernetes.io/zone
  operator: In
  values: ["us-east-2a"]  # Change to your target AZ
```

### Apply the manifests

```sh
kubectl apply -f static-nodeclass.yaml
kubectl apply -f static-nodepool.yaml
```

Since `replicas` is set, Karpenter provisions the nodes without any pending pods.

## Results

After a few minutes, Karpenter provisions a `g6e.8xlarge` matching the `replicas: 1` spec.

**Check nodes:**
```sh
kubectl get nodes -l capacity-type=gpu-static -o custom-columns="NAME:.metadata.name,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,READY:.status.conditions[-1].status,AGE:.metadata.creationTimestamp"
```

**Expected output:**
```
NAME                                          INSTANCE        READY   AGE
ip-10-0-x-x.region.compute.internal           g6e.8xlarge     True    2026-04-14T00:00:00Z
```

**Check NodePool status:**
```sh
kubectl get nodepool
```

**Expected output:**
```
NAME                     NODECLASS                NODES   READY   AGE
gpu-static               gpu-static               1       True    48s
...
```

<details>
<summary><strong>EKS Auto Mode</strong></summary>

**Prerequisite:** an EKS cluster with Auto Mode enabled, and an EKS Access Entry granting `AmazonEKSAutoNodePolicy` to the node IAM role used by Auto Mode.

> If you're using the Terraform template under [`cluster/automode/`](../../cluster/automode/) in this repo, the cluster, node IAM role, and Access Entry are all created for you — you can skip the manual access entry steps below.

EKS Auto Mode supports static capacity NodePools with the same `spec.replicas` field — see the [Static Capacity Node Pools in EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/auto-static-capacity.html) documentation. **No `StaticCapacity` feature gate flip is needed** — the managed Karpenter in Auto Mode exposes this directly.

The Auto Mode NodeClass collapses to a minimal form: no `amiSelectorTerms`, no `role`, no `blockDeviceMappings`, no `instanceStorePolicy`, and no `networkInterfaces`. EFA, ENA, and instance store policy are managed by Auto Mode. NVIDIA drivers and the device plugin are also included automatically — no extra install needed.

To deploy on Auto Mode, replace `<<CLUSTER_NAME>>` and apply:

```sh
sed -i "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" static-nodeclass-automode.yaml
kubectl apply -f static-nodeclass-automode.yaml
kubectl apply -f static-nodepool-automode.yaml
```

Differences from the OSS version:
- `NodeClass` (`eks.amazonaws.com/v1`) replaces `EC2NodeClass` (`karpenter.k8s.aws/v1`)
- `networkInterfaces`, `instanceStorePolicy`, `amiSelectorTerms`, `role`, and `blockDeviceMappings` are removed — Auto Mode manages these
- The `vpc.amazonaws.com/efa.present` label is dropped from the NodePool template (Auto Mode handles EFA differently — see the [EFA on Auto Mode docs](https://docs.aws.amazon.com/eks/latest/userguide/manage-efa.html))
- No `StaticCapacity` feature gate flip — `spec.replicas` is supported natively

The OSS blueprint demonstrates `placementGroupSelector` and `capacityReservationSelectorTerms` for ODCR / Capacity Blocks. Auto Mode handles capacity reservations through different mechanisms — refer to the [EKS Auto Mode documentation](https://docs.aws.amazon.com/eks/latest/userguide/automode.html) for the current support matrix.

If you are **not** using the `cluster/automode/` Terraform template, configure the Access Entry manually:

```sh
aws eks create-access-entry \
  --cluster-name $CLUSTER_NAME \
  --principal-arn <node-role-arn> \
  --type EC2

aws eks associate-access-policy \
  --cluster-name $CLUSTER_NAME \
  --principal-arn <node-role-arn> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy \
  --access-scope type=cluster
```
</details>

## Clean-up

To clean-up execute the following commands:

```sh
kubectl delete -f static-nodepool.yaml
kubectl delete -f static-nodeclass.yaml
```
