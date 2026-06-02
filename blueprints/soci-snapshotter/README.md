
# Karpenter Blueprint: Using SOCI snapshotter parallel pull/unpack mode

## Purpose

Container image pull performance has become a bottleneck as container images grow larger, compared to when typical images were just a few hundred megabytes.
The default pulling method uses sequential layer downloading and unpacking. SOCI parallel pull/unpack mode accelerates container image loading through concurrent downloads and unpacking operations, reducing image pull time by up to 50%. This makes it ideal for AI/ML and Batch workloads, where it is common for those applications to have a large container images.

This blueprint demonstrate how to setup SOCI snapshotter parallel pull/unpack mode on AL2023 and Bottlerocket through a custom `EC2NodeClass` and customizing the `userData` field.

> ***NOTE***: SOCI snapshotter parallel mode is supported on [Amazon Linux 2023 (AL2023) > v20250821](https://github.com/awslabs/amazon-eks-ami/releases/tag/v20250821) and [Bottlerocket > v1.44.0](https://github.com/bottlerocket-os/bottlerocket/releases/tag/v1.44.0)

If you would like to learn more about SOCI snapshotter's new parallel pull/unpack mode you can visit the following resources:
1. [SOCI snapshotter parallel mode feature docs](https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md) in the [SOCI project repository](https://github.com/awslabs/soci-snapshotter) on GitHub.
2. [Introducing Seekable OCI Parallel Pull mode for Amazon EKS](https://aws.amazon.com/blogs/containers/introducing-seekable-oci-parallel-pull-mode-for-amazon-eks/) Blog post.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A Container Registry that supports HTTP range GET requests such as [Amazon Elastic Container Registry (ECR)](https://aws.amazon.com/ecr/)

## Deploy

You need to create a new `EC2NodeClass` with the `userData` field and customize the root volume EBS with `blockDeviceMappings`, along with a `NodePool` to use this new template.

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role(not the ARN).

Now, make sure you're in this blueprint folder, then run the following command:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" soci-snapshotter.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" soci-snapshotter.yaml
sed -i '' "s/<<AWS_REGION>>/$AWS_REGION/g" workload.yaml
kubectl apply -f .
```

> ***NOTE***: It can take a couple of minutes for resource to be created, while resources are being created you can continue reading.

Those commands creates the following:
1. `EC2NodeClass` and `NodePool` named `soci-snapshotter` for using SOCI snapshotter parallel pull/unpack mode with customized `blockDeviceMappings` for increased I/O and storage size on Amazon Linux 2023.
2. `EC2NodeClass` and `NodePool` named `soci-snapshotter-br` for using SOCI snapshotter parallel pull/unpack mode with customized `blockDeviceMappings` for increased I/O and storage size on Bottlerocket.
3. `EC2NodeClass` and `NodePool` named `non-soci-snapshotter` for using default containerd implementation with customized `blockDeviceMappings` for increased I/O and storage size.
4. Kubernetes `Deployment` named `vllm-soci` that uses the `soci-snapshotter` `NodePool`
5. Kubernetes `Deployment` named `vllm-soci-br` that uses the `soci-snapshotter-br` `NodePool`
6. Kubernetes `Deployment` named `vllm` that uses the `non-soci-snapshotter` `NodePool`

> ***NOTE***: For our example both deployments will request instances that have network and ebs bandwidth greater than 8000 Mbps by using `nodeAffinity` in order to eliminate network and storage I/O bottlenecks to demonstrate SOCI parallel mode capabilities.
```
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: karpenter.k8s.aws/instance-ebs-bandwidth
                operator: Gt
                values:
                - "8000"
              - key: karpenter.k8s.aws/instance-network-bandwidth
                operator: Gt
                values:
                - "8000"
```
## Configuration

The SOCI snapshotter `EC2NodeClass` configuration have several configuration parameters that affect SOCI parallel mode performance.

The `blockDeviceMapping` field is used to increase root volume EBS performance and storage size.\
The `instanceStorePolicy: RAID0` tells Karpenter to automatically configure a `RAID0` array from all available NVMe instance store disks on the node. It then moves `/var/lib/containerd`, `/var/lib/kubelet`, `/var/log/pods` and SOCI's data dir (`/var/lib/soci-snapshotter-grpc` or `/var/lib/soci-snapshotter` on AL2023 and Bottlerocket accordingly) to that array and symlinks them back.

As SOCI parallel mode downloads layers, it buffers them on disk instead of in-memory, having a high performant storage subsystem is crucial to support it as well as enough storage to hold the container images.
The example configure the root volume with IOPs of 16,000 and throughput of 1,000MiB/s which is the maximum for GP3, it is recommended that you modify those settings accordingly to trade-off between performance and cost.
> ***NOTE***: From our benchmarks, we have also seen a good starting point by setting the throughput to 600MiB/s and keeping base IOPs to 3,000.

<details>
<summary>Amazon Linux 2023</summary>

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter
...
...
spec:
  blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      volumeSize: 100Gi
      volumeType: gp3
      throughput: 1000
      iops: 16000
...
...
```
</details>
<details>
<summary>Bottlerocket</summary>

Bottlerocket defaults to two block devices, one for Bottlerocket's control volume and the other for container resources such as images and logs, in the example below we have configured Bottlerocket's secondary block device with increased EBS storage & throughput to support SOCI parallel mode.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter-br
...
...
spec:
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
        encrypted: true
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        throughput: 1000
        iops: 16000
        encrypted: true
...
...
```

</details>
<br>

The `userData` field is used to enable and configure SOCI snapshotter on AL2023 and Bottlerocket.

SOCI parallel mode configuration is controlled by several key settings. While the default values align with containerd's standard configuration to ensure stability and safety, you can adjust these parameters to optimize performance based on your specific needs, but ensure the infastructure can support it.

1. `max_concurrent_downloads_per_image`: Limits the maximum concurrent downloads per individual image, Default is 3 for Bottlerocket and 20 for AL2023. For images hosted on Amazon ECR we recommend setting this to 10-20.
2. `max_concurrent_unpacks_per_image`: Sets the limit for concurrent unpacking of layers per image. Default is 1 for Bottlerocket and 12 for AL2023. Tuning this to match the number of avg layers count of your container images.
3. `concurrent_download_chunk_size`: Specifies the size of each download chunk when pulling image layers in parallel. Default is "unlimited" for Bottlerocket and "16mb" for AL2023. This feature will enable multiple concurrent downloads per layer, we recommend setting this value to >0 if your registry support HTTP range requests, if you're using ECR, we recommend setting this to "16mb".
4. `discard_unpacked_layers`: Controls whether to retain layer blobs after unpacking. Enabling this can reduce disk space usage and speed up pull times. Default is false for Bottlerocket and true for AL2023. We recommend to set this to true on EKS nodes.

| Parameter | AL2023 Default | Bottlerocket Default | Recommendation |
|-----------|---------------|---------------------|----------------|
| `max_concurrent_downloads_per_image` | 20 | 3 | 10-20 (for ECR) |
| `max_concurrent_unpacks_per_image` | 12 | 1 | Match avg layer count of your images |
| `concurrent_download_chunk_size` | 16mb | unlimited | 16mb (if registry supports HTTP range requests) |
| `discard_unpacked_layers` | true | false | true on EKS nodes |

To learn more about other configuration options, visit the [official SOCI snapshotter doc](https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md#configuration)

As installing a snapshotter to containerd and EKS requires several configuration, this is all being done for you automatically in AL2023 and Bottlerocket as SOCI is already pre-installed in the latest AMIs.

<details>
<summary>Amazon Linux 2023</summary>

SOCI snapshotter parallel mode can be enabled in AL2023 through featureGate named "FastImagePull", in AL2023 we use [`NodeConfig`](https://awslabs.github.io/amazon-eks-ami/nodeadm/doc/examples/#enabling-fast-image-pull-experimental) simplify various data plane configurations.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter
...
...
spec:
...
...
  userData: |
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      featureGates:
        FastImagePull: true
```

Modifying SOCI snapshotter parallel mode configuration in AL2023 requires modifying the `/etc/soci-snapshotter-grpc/config.toml` file, this can be achieved by a `userData` script as additional to the `NodeConfig` configuration.

The following sets `max_concurrent_downloads_per_image` and `max_concurrent_unpacks_per_image` to `10` respectively and also configure `discard_unpacked_layers` to `false` to keep unpacked layers.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter
...
...
spec:
...
...
  userData: |
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="//"

    --//
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    max_concurrent_downloads_per_image=10
    max_concurrent_unpacks_per_image=10
    discard_unpacked_layers=false

    sed -i "s/^max_concurrent_downloads_per_image = .*$/max_concurrent_downloads_per_image = $max_concurrent_downloads_per_image/" /etc/soci-snapshotter-grpc/config.toml
    sed -i "s/^max_concurrent_unpacks_per_image = .*$/max_concurrent_unpacks_per_image = $max_concurrent_unpacks_per_image/" /etc/soci-snapshotter-grpc/config.toml
    sed -i "s/^discard_unpacked_layers = .*$/discard_unpacked_layers = $discard_unpacked_layers/" /etc/soci-snapshotter-grpc/config.toml

    --//
    Content-Type: application/node.eks.aws

    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      featureGates:
        FastImagePull: true
      containerd:
        config: |
          [plugins.'io.containerd.cri.v1.images']
          discard_unpacked_layers = false
    --//
```

</details>

<details>
<summary>Bottlerocket</summary>

SOCI snapshotter parallel mode can be enabled and configured in Bottlerocket through the [Settings API](https://bottlerocket.dev/en/os/1.60.x/api/settings/container-runtime-plugins/#tag-soci-parallel-pull-configuration).

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter-br
...
...
spec:
...
...
  userData: |
    [settings.container-runtime]
    snapshotter = "soci"

    [settings.container-runtime-plugins.soci-snapshotter]
    pull-mode = "parallel-pull-unpack"

    [settings.container-runtime-plugins.soci-snapshotter.parallel-pull-unpack]
    max-concurrent-downloads-per-image = 20
    concurrent-download-chunk-size = "16mb"
    max-concurrent-unpacks-per-image = 12
    discard-unpacked-layers = true
```
</details>

## Using `instanceStorePolicy: RAID0` with EBS for SOCI Data

### Background

When `instanceStorePolicy: RAID0` is configured, Karpenter assembles all available NVMe instance store disks into a RAID0 array and moves container runtime directories onto it, including SOCI's data directory. This provides maximum I/O throughput for image pulls.

However, not all NVMe instance store disks are equal, different instance types have varying NVMe storage capacity, read/write IOPS, and throughput specifications (see [EC2 instance type specifications](https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-type-specifications.html)). In these cases, you may want SOCI's data directory to remain on EBS (where you control size, IOPS, and throughput) while still benefiting from the RAID0 array for containerd, kubelet, and pod logs.

The workaround is to keep the RAID0 array for container runtime paths but have SOCI's data directory on EBS, giving you consistent and predictable storage performance.

<details>
<summary><strong>Amazon Linux 2023</strong></summary>

On AL2023, `instanceStorePolicy: RAID0` binds `/var/lib/soci-snapshotter-grpc` to the NVMe RAID0 array by default. To override this and keep SOCI data on EBS, remove `instanceStorePolicy` from the `EC2NodeClass` and use nodeadm's `NodeConfig` to manually stripe the NVMe disks into a RAID0 array while excluding SOCI's data directory from the bind:

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter
spec:
...
...
  # NOTE: No instanceStorePolicy here — we manage it manually through NodeConfig
  blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      volumeSize: 100Gi
      volumeType: gp3
      throughput: 1000
      iops: 16000
...
...
  userData: |
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      instance:
        localStorage:
          strategy: RAID0
          disabledMounts:
            - SOCI
      featureGates:
        FastImagePull: true
    --//
```

What this does:

1. **Removes `instanceStorePolicy: RAID0`** from the EC2NodeClass so Karpenter doesn't automatically binds all directories (including SOCI's) to the NVMe array.
2. **Uses nodeadm's `localStorage` configuration** with `strategy: RAID0` to stripe all NVMe instance store disks into a RAID0 array, and `disabledMounts: [SOCI]` to exclude SOCI's data directory from being moved to the array.
3. **Result**: containerd, kubelet, and pod logs benefit from NVMe RAID0 speed, while SOCI's layer data (`/var/lib/soci-snapshotter-grpc`) remains on the  EBS volume with predictable capacity & performance.

</details>

<details>
<summary><strong>Bottlerocket</strong></summary>

On Bottlerocket, the approach is similar to AL2023: remove `instanceStorePolicy: RAID0` from the `EC2NodeClass` and manually initialize the NVMe RAID0 array via bootstrap commands, binding only the directories you want on instance store, explicitly excluding `/var/lib/soci-snapshotter`:

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter-br
spec:
...
...
  # NOTE: No instanceStorePolicy here — we manage it manually via bootstrap commands
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
        encrypted: true
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        throughput: 1000
        iops: 16000
        encrypted: true
...
...
  userData: |
    [settings.container-runtime]
    snapshotter = "soci"

    [settings.container-runtime-plugins.soci-snapshotter]
    pull-mode = "parallel-pull-unpack"

    [settings.container-runtime-plugins.soci-snapshotter.parallel-pull-unpack]
    max-concurrent-downloads-per-image = 20
    concurrent-download-chunk-size = "16mb"
    max-concurrent-unpacks-per-image = 12
    discard-unpacked-layers = true

    [settings.bootstrap-commands.k8s-ephemeral-storage]
    commands = [
        ["apiclient", "ephemeral-storage", "init"],
        ["apiclient", "ephemeral-storage", "bind", "--dirs", "/var/lib/containerd", "/var/lib/kubelet", "/var/log/pods"]
    ]
    essential = true
    mode = "always"
```

What this does:

1. **Removes `instanceStorePolicy: RAID0`** from the EC2NodeClass so Karpenter doesn't automatically binds all directories (including SOCI's) to the NVMe array.
2. **Manually initializes the RAID0 array** using `apiclient ephemeral-storage init` this stripes all NVMe disks into a RAID0.
3. **Selectively binds only `/var/lib/containerd`, `/var/lib/kubelet`, and `/var/log/pods`** to the NVMe array, deliberately omitting `/var/lib/soci-snapshotter`.
3. **Result**: containerd, kubelet, and pod logs benefit from NVMe RAID0 speed, while SOCI's layer data (`/var/lib/soci-snapshotter`) remains on the  EBS volume (`/dev/xvdb`) with predictable capacity & performance.

</details>

### Summary

| OS | Approach | SOCI data lives on | Runtime dirs on NVMe |
|----|----------|-------------------|---------------------|
| AL2023 | Remove `instanceStorePolicy`, use nodeadm `localStorage` with `disabledMounts: [SOCI]` | EBS (`/var/lib/soci-snapshotter-grpc`) | Yes |
| Bottlerocket | Remove `instanceStorePolicy`, manually init RAID0 and bind specific dirs | EBS (`/var/lib/soci-snapshotter`) | Yes |

This pattern is particularly useful for GPU instances (e.g., `g5`, `g6`) where NVMe performance vary by instance size but you still want fast I/O for kubelet and containerd operations, while giving SOCI the full capacity and consistent performance of a provisioned EBS volume.

## Results

Wait until the pods from the sample workload are in running status:
```sh
> kubectl wait --for=condition=Ready pods --all --namespace default --timeout=300s
pod/vllm-56cb5d8b67-jbz6j condition met
pod/vllm-soci-6fd6556648-gxw98 condition met
pod/vllm-soci-br-6fc95c9b74-wsr5s condition met
```

The sample workload deploys three Deployments running [Amazon Deep Learning Container (DLC) for vLLM](https://aws.github.io/deep-learning-containers/reference/available_images/#vllm-ubuntu), two using SOCI parallel pull/unpack mode (AL2023, Bottlerocket) and one remains using the default containerd implementation.
> ***NOTE*** The Amazon DLC for vLLM container image size is about **~9GB**

Let's examine the pull time for each Deployment:

The `vllm` deployment using the default containerd implementation results in pull time of **2m10.813s**.
```sh
> kubectl describe pod -l app=vllm | grep Pulled
  Normal   Pulled            72s                    kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2"
  in 2m10.813s (2m10.813s including waiting). Image size: 9354342327 bytes.
```

The `vllm-soci` deployment using SOCI snapshotter's parallel pull/unpack mode implementation results in pull time of **39.553s**.
```sh
> kubectl describe pod -l app=vllm-soci | grep Pulled
  Normal   Pulled            89s                    kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2"
  in 39.553s (39.553s including waiting). Image size: 9354342327 bytes.
```

The `vllm-soci-br` deployment using SOCI snapshotter's parallel pull/unpack mode implementation on Bottlerocket, results in pull time of **23.229s**.
```sh
> kubectl describe pod -l app=vllm-soci-br | grep Pulled
  Normal   Pulled            2m10s                  kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2"
  in 23.229s (23.229s including waiting). Image size: 9354342327 bytes
```

We can see that using SOCI snapshotter's improved container pull time by about **70%** on Amazon Linux 2023, and about **80%** on Bottlerocket, the reason for that is that Bottlerocket have an improved decompression library for Intel based CPUs ([bottlerocket-core-kit PR #443](https://github.com/bottlerocket-os/bottlerocket-core-kit/pull/443))


<details>
<summary><strong>EKS Auto Mode</strong></summary>

**Prerequisite:** an EKS cluster with Auto Mode enabled, and an EKS Access Entry granting `AmazonEKSAutoNodePolicy` to the node IAM role used by Auto Mode.

> If you're using the Terraform template under [`cluster/automode/`](../../cluster/automode/) in this repo, the cluster, node IAM role, and Access Entry are all created for you — you can skip the manual access entry steps below.

SOCI parallel pull/unpack mode is **built into Auto Mode's Bottlerocket nodes by default** (since the [November 19, 2025 Auto Mode change](https://docs.aws.amazon.com/eks/latest/userguide/auto-change.html#_november_19_2025)). No `userData` configuration is needed. The OSS blueprint's three-way comparison (AL2023 SOCI, Bottlerocket SOCI, non-SOCI baseline) collapses to a single Auto Mode NodePool because Auto Mode runs Bottlerocket variant only and SOCI is always enabled **only** on selected G, P, and Trn family instances with local NVMe storage only, there is no opt-out path to demonstrate a non-SOCI baseline.

To deploy on Auto Mode, use the single combined manifest:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" ./auto-mode/soci-snapshotter.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" ./auto-mode/soci-snapshotter.yaml
sed -i '' "s/<<AWS_REGION>>/$AWS_REGION/g" ./auto-mode/workload.yaml
kubectl apply -f ./auto-mode
```

Differences from the OSS version:
- Single `NodeClass` + `NodePool` pair instead of three (no AL2023, no non-SOCI baseline)
- `userData`, `instanceStorePolicy`, and `blockDeviceMappings` are removed — Auto Mode + Bottlerocket handle these
- Instance label keys use the `eks.amazonaws.com/` prefix instead of `karpenter.k8s.aws/`
- The OSS workload's `karpenter.k8s.aws/instance-ebs-bandwidth` and `karpenter.k8s.aws/instance-network-bandwidth` node-affinity keys become `eks.amazonaws.com/instance-ebs-bandwidth` and `eks.amazonaws.com/instance-network-bandwidth`

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

## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete -f .
kubectl delete -f ./auto-mode
```

