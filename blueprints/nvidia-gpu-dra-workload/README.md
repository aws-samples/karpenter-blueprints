# Karpenter Blueprint: Deploy an NVIDIA GPU workload with Dynamic Resource Allocation

## Purpose

[Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/resource-management/dynamic-resource-allocation/) with the [NVIDIA DRA driver](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/dra-intro-install.html) enables a Pod to describe the GPU it requires, by model, architecture, or memory, instead of requesting `nvidia.com/gpu: 1`. It does this through a `ResourceClaim`. Karpenter carries per-instance-type metadata about which GPUs each type publishes, so it can match a pending claim's CEL selector against that metadata and launch the right instance before any GPU node exists.

Use this blueprint to get started with the NVIDIA DRA driver on Karpenter.

## Requirements

* An Amazon EKS cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
  * **EKS 1.34 or later**, for the `resource.k8s.io` DRA APIs.
  * **Karpenter v1.15 or later**, which adds Alpha support for NVIDIA DRA and EFA DRA provisioning.
* Karpenter's DRA support must be enabled with the `settings.enableDRA` Helm value (Alpha, default `false`):

```sh
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --set "settings.enableDRA=true" \
  --reuse-values
```

`DRANVIDIAGPU` is an AWS-specific feature gate, so it's surfaced through the `AWS_FEATURE_GATES` env var on the Karpenter controller. Verify it's enabled:

```sh
kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_FEATURE_GATES")].value}'
```

You should see `DRANVIDIAGPU=true` in the output.

## Install the NVIDIA GPU Operator to manage the DRA driver

Add the NVIDIA GPU Operator Helm repository:

```sh
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
```

The EKS Bottlerocket and AL2023 NVIDIA AMIs contain the host NVIDIA driver and the NVIDIA Container Toolkit, so install the Operator in **pre-installed driver** mode: set `clusterPolicy.deployCR=false` (don't manage the Device Plugin stack) and `gpuCluster.deployCR=true` (create the `GPUCluster` resource that manages the DRA driver). We also disable ComputeDomains, since that feature targets Multi-Node NVLink hardware (for example, GB200):

```sh
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --version=v26.7.2 \
  --namespace gpu-operator \
  --create-namespace \
  --set clusterPolicy.deployCR=false \
  --set gpuCluster.deployCR=true \
  --set driver.enabled=false \
  --set toolkit.enabled=false \
  --set gfd.enabled=false \
  --set draDriver.computeDomains.enabled=false
```

| Helm value | Why |
|---|---|
| `clusterPolicy.deployCR=false` | Don't create the Device Plugin-based `ClusterPolicy`; a cluster can only run one of `ClusterPolicy`/`GPUCluster`. |
| `gpuCluster.deployCR=true` | Create the `gpu-cluster` `GPUCluster` resource to manage the DRA driver. |
| `driver.enabled=false`, `toolkit.enabled=false` | The Bottlerocket NVIDIA AMI already has the NVIDIA driver and container toolkit installed on the host, so don't let the Operator manage or reinstall either. |
| `gfd.enabled=false` | GFD's only job here ([DRA driver prerequisites](https://dra-driver-nvidia-gpu.sigs.k8s.io/docs/prerequisites/)) is generating the `nvidia.com/gpu.clique` label for ComputeDomains, which we're disabling below. |
| `draDriver.computeDomains.enabled=false` | Disables the ComputeDomain controller/kubelet-plugin, which Karpenter can't provision for and which this blueprint's instance types don't support. |

> **NOTE**: Do not run the NVIDIA DRA driver alongside the NVIDIA device plugin on the same node. The Bottlerocket NVIDIA variant ships with the device plugin enabled by default, so the EC2NodeClass below disables it via `userData`. Keep DRA nodes and device-plugin nodes on separate NodePools, and if you've already tested the [nvidia-gpu-workload](/blueprints/nvidia-gpu-workload/) blueprint, uninstall its device plugin first.

You might also decide instead to use the standalone NVIDIA DRA helm chart.

Check the status, this typically completes within a few minutes:

**Verify the DRA driver pods are running** in the `gpu-operator` namespace:

```sh
kubectl get pods -n gpu-operator
```

You should see `nvidia-dra-driver-kubelet-plugin`, `nvidia-dra-validator`, and `nvidia-dcgm-exporter-dra` pods once a GPU node joins the cluster.

**Verify the DeviceClass objects were created:**

```sh
kubectl get deviceclass
```

**Expected output** (without ComputeDomains enabled, you only see the GPU-related classes):
```
NAME               AGE
gpu.nvidia.com      60s
mig.nvidia.com      60s
vfio.gpu.nvidia.com 60s
```

## Deploy

Before applying the manifests, set your cluster-specific variables. If you're using the Terraform template provided in this repo, run the following commands:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/docs/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`.

### Create the EC2NodeClass

This `EC2NodeClass` uses the Bottlerocket EKS AMI and disable use of the NVIDIA device plugin:

```sh
cat << EOF > gpu-dra-nodeclass.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-dra
spec:
  amiSelectorTerms:
  - alias: bottlerocket@latest
  role: "$KARPENTER_NODE_IAM_ROLE_NAME"
  instanceStorePolicy: RAID0
  userData: |
    [settings.kubelet-device-plugins.nvidia]
    enabled = false
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: $CLUSTER_NAME
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: $CLUSTER_NAME
EOF
```

### Create the NodePool

Rather than pin an exact instance type, the requirements stay broad: any on-demand or spot NVIDIA EC2 instance in the `g` category. The `ResourceClaimTemplate`'s GPU-model selector indicates which GPU by product name to allocate to the workload.

```sh
cat << EOF > gpu-dra-nodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-dra
spec:
  limits:
    nodes: 1
  template:
    metadata:
      labels:
        nvidia.com/gpu.present: "true"
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        name: gpu-dra
        kind: EC2NodeClass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["g"]
        - key: karpenter.k8s.aws/instance-gpu-manufacturer
          operator: In
          values: ["nvidia"]
      expireAfter: Never
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
EOF
```

### Create the ResourceClaimTemplate, specifying a GPU by product name

```sh
cat << EOF > resourceclaim-gpu-a10g.yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: gpu-a10g
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
          selectors:
          - cel:
              expression: |-
                device.attributes["gpu.nvidia.com"].productName == "NVIDIA A10G"
EOF
```

> **NOTE**: `NVIDIA A10G` is the exact `productName` Karpenter expects for `g5` instances, per the [Supported Instance Types table](https://karpenter.sh/docs/tasks/dra/#supported-instance-types) in the Karpenter DRA docs. You can cross check against a live cluster instead with `kubectl describe resourceslice` once a GPU node is up, which shows what the DRA driver is publishing for that device, for example:

```
Spec:
  Devices:
    Attributes:
      Addressing Mode:
        String:  None
      Architecture:
        String:  Ampere
      Brand:
        String:  Nvidia
      Cuda Compute Capability:
        Version:  8.6.0
      Cuda Driver Version:
        Version:  13.0.0
      Driver Version:
        Version:  580.178.4
      Product Name:
        String:  NVIDIA A10G
      resource.kubernetes.io/pciBusID:
        String:  0000:00:1e.0
      resource.kubernetes.io/pcieRoot:
        String:  pci0000:00
      Type:
        String:  gpu
      Uuid:
        String:  GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    Capacity:
      Memory:
        Value:  23028Mi
```

The `Product Name` field here (`device.attributes["gpu.nvidia.com"].productName` from the claim's CEL expression) is what the selector above matches against.

### Deploy the workload

Create the workloads Kubernetes manifest:

```sh
cat << EOF > workload.yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-dra-demo
  labels:
    app: gpu-dra-demo
spec:
  nodeSelector:
    karpenter.sh/nodepool: gpu-dra
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  restartPolicy: Always
  containers:
    - name: gpu-demo
      image: public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
      command: ["/bin/sh", "-c", "nvidia-smi --query-gpu=name,uuid --format=csv,noheader; sleep infinity"]
      resources:
        claims:
        - name: gpu
  resourceClaims:
    - name: gpu
      resourceClaimTemplateName: gpu-a10g
EOF
```

### Apply the manifests

```sh
kubectl apply -f gpu-dra-nodeclass.yaml
kubectl apply -f gpu-dra-nodepool.yaml
kubectl apply -f resourceclaim-gpu-a10g.yaml
kubectl apply -f workload.yaml
```

Karpenter sees the pending DRA Pod, evaluates its claim's CEL selector against its GPU instance-type metadata, and launches the instance type that has an A10G.

## Results

**Check the node and instance type Karpenter chose:**

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-dra -o custom-columns="NAME:.metadata.name,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,READY:.status.conditions[-1].status"
```

**Expected output:**
```
NAME            INSTANCE     READY
gpu-dra-xxxxx   g5.xlarge    True
```

**Verify a ResourceSlice was published for the GPU node:**

```sh
kubectl get resourceslice
```

**Confirm the Pod is running and reports the expected GPU:**

```sh
kubectl get pod gpu-dra-demo
kubectl logs gpu-dra-demo
```

**Expected output:**
```
NVIDIA A10G, GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

## Clean-up

To clean-up execute the following commands:

```sh
kubectl delete -f workload.yaml
kubectl delete -f resourceclaim-gpu-a10g.yaml
kubectl delete -f gpu-dra-nodepool.yaml
kubectl delete -f gpu-dra-nodeclass.yaml
helm -n gpu-operator uninstall gpu-operator
```
