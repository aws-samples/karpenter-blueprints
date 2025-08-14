
# Karpenter Blueprint: Using SOCI snapshotter parallel pull/unpack mode

## Purpose

Container image pull performance has become a bottleneck as container images grow larger, compared to when typical images were just a few hundred megabytes.
The default pulling method uses sequential layer downloading and unpacking. SOCI parallel pull/unpack mode accelerates container image loading through concurrent downloads and unpacking operations, reducing image pull time by up to 50%. This makes it ideal for AI/ML and Batch workloads, where it is common for those applications to have a large container images.

This blueprint demonstrate how to setup SOCI snapshotter parallel pull/unpack mode on AL2023 through a custom `EC2NodeClass` and customizing the `userData` field.

> ***NOTE***: In this example we demonstrate SOCI snapshotter on Amazon Linux 2023 (AL2023) and Bottlerocket. While SOCI snapshotter can be supported on other distros, we use this example on AL2023 and Bottlerocket that uses `userData` to simplify the customization of `containerd` and `kubelet` configuration. If you would like to setup on other distros, you can use the installation script provided in the example but you will have to customize `containerd` and `kubelet` configuration yourself.

If you would like to learn more about SOCI snapshotter's new parallel pull/unpack mode you can visist the following resources:
1. [SOCI snapshotter parallel mode docs](https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md)
2. [Accelerate container startup time on Amazon EKS with SOCI parallel mode](https://builder.aws.com/content/30EkTz8DbMjuqW0eHTQduc5uXi6/accelerate-container-startup-time-on-amazon-eks-with-soci-parallel-mode)

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

The `blockDeviceMapping` field is used to increase root volume EBS performance and storage size.
As SOCI parallel mode downloads layers, it buffers them on disk instead of in-memory, having a high performant storage subsystem is crucial to support it as well as enough storage to hold the container images.
The example configure the root volume with IOPs of 16,000 and throughput of 1,000MiB/s which is the maximum for GP3, it is recommended that you modify those settings accordingly to trade-off between performance and cost.
> ***NOTE***: From our benchmarks, we have also seen a good starting point by setting the throughput to 600MiB/s and keeping base IOPs to 3,000.

We also set the `instanceStorePolicy: RAID0` field on AL2023, that will utilize instance store NVMe disks, in case of multiple disks, it will stripe them as RAID0, mount them, and make sure containerd root dir is used on those disks.
If the `EC2NodeClass` is being used with `NodePool` that only launch instances with instance store, the `blockDeviceMappings` can be removed to reduce cost, as SOCI snapshotter root dir is configured to use containerd root dir and will utilize instance store which are high performant NVMe disks.

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
  instanceStorePolicy: RAID0
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

The `userData` field is used to initiate the SOCI snapshotter setup and to configure containerd and kubelet.

SOCI parallel mode configuration is controlled by several key settings. While the default values align with containerd's standard configuration to ensure stability and safety, you can adjust these parameters to optimize performance based on your specific needs, but ensure the infastructure can support it.

1. `max_concurrent_downloads_per_image`: Limits the maximum concurrent downloads per individual image, Default is 3. For images hosted on Amazon ECR we recommend setting this to 10-20.
2. `max_concurrent_unpacks_per_image`: Sets the limit for concurrent unpacking of layers per image. Default is 1. Tuning this to match the number of avg layers count of your container images.
3. `soci_root_dir`: where downloaded data is stored and extracted, this path should be backed by an high performance storage subsystem. Default is "/var/lib/soci-snapshotter-grpc". We have set this under /var/lib/containerd where containerd data is stored to benefit when using `instanceStorePolicy: RAID0`.

The second part of the `userData` handles the configuration of containerd and kubelet through [`NodeConfig`](https://awslabs.github.io/amazon-eks-ami/nodeadm/) which is only supported on AL2023 and simplify various data plane configurations, Bottlerocket by default configure containerd and kubelet when enabling SOCI parallel mode.

<details>
<summary>Amazon Linux 2023</summary>

1. We configure the `kubelet` image service endpoint to use SOCI as the image service proxy to cache credentials, you can read more on this [here](https://github.com/awslabs/soci-snapshotter/blob/main/docs/registry-authentication.md#kubernetes-cri-credentials)
2. We configure `containerd` to introduce a new snapshotter plugin as well as configure the default snapshotter to use the configured SOCI snapshotter.

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
    export max_concurrent_downloads_per_image=10
    export max_concurrent_unpacks_per_image=10
    export soci_root_dir=/var/lib/containerd/io.containerd.snapshotter.v1.soci
    curl -sSL https://raw.githubusercontent.com/awslabs/soci-snapshotter/refs/heads/main/scripts/parallel-mode-install.sh | bash

    --//
    Content-Type: application/node.eks.aws

    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          imageServiceEndpoint: unix:///run/soci-snapshotter-grpc/soci-snapshotter-grpc.sock
      containerd:
        config: |
          [proxy_plugins.soci]
            type = "snapshot"
            address = "/run/soci-snapshotter-grpc/soci-snapshotter-grpc.sock"
          [proxy_plugins.soci.exports]
            root = "/var/lib/containerd/io.containerd.snapshotter.v1.soci"
          [plugins."io.containerd.grpc.v1.cri".containerd]
            snapshotter = "soci"
            disable_snapshot_annotations = false
    --//
```
</details>

<details>
<summary>Bottlerocket</summary>

SOCI is integrated into Bottlerocket latest AMIs and simplify setup and configuration through Bottlerocket APIs as in the example below.

In Bottlerocket, SOCI's data dir is configured at `/var/lib/soci-snapshotter`, to take advantage of instances with NVMe disks, we will need to configure ephemeral storage through Bottlerocket's Settings API, replacing `instanceStorePolicy: RAID0` with `[settings.bootstrap-commands.k8s-ephemeral-storage]` as you can see below, we added `/var/lib/soci-snapshotter` as a bind dir.

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
    max-concurrent-downloads-per-image = 10
    concurrent-download-chunk-size = "16mb"
    max-concurrent-unpacks-per-image = 10
    discard-unpacked-layers = true
    [settings.bootstrap-commands.k8s-ephemeral-storage]
    commands = [
        ["apiclient", "ephemeral-storage", "init"],
        ["apiclient", "ephemeral-storage" ,"bind", "--dirs", "/var/lib/containerd", "/var/lib/kubelet", "/var/log/pods", "/var/lib/soci-snapshotter"]
    ]
    essential = true
    mode = "always"
```
</details>

## Results

Wait until the pods from the sample workload are in running status:
```sh
> kubectl wait --for=condition=Ready pods --all --namespace default --timeout=300s
pod/vllm-59bfb6f86c-9nfxb condition met
pod/vllm-soci-6d9bfd996d-vhr4j condition met
pod/vllm-soci-br-74b59cc4bd-rq8cw condition met
```

The sample workload deploys three Deployments running [Amazon Deep Learning Container (DLC) for vLLM](https://docs.aws.amazon.com/deep-learning-containers/latest/devguide/dlc-vllm-x86-ec2.html) two using SOCI parallel pull/unpack mode (AL2023, Bottlerocket) and one remains using the default containerd implementation.
> ***NOTE*** The Amazon DLC for vLLM container image size is about **~10GB**

Let's examine the pull time for each Deployment:

The `vllm` deployment using the default containerd implementation results in pull time of **1m52.33s**.
```sh
> kubectl describe pod -l app=vllm | grep Pulled
  Normal   Pulled            7m2s   kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.9-gpu-py312-ec2"
  in 1m52.33s (1m52.33s including waiting). Image size: 10778400361 bytes.
```

The `vllm-soci` deployment using SOCI snapshotter's parallel pull/unpack mode implementation results in pull time of **59.813s**.
```sh
> kubectl describe pod -l app=vllm-soci | grep Pulled
  Normal   Pulled            8m27s  kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.9-gpu-py312-ec2"
  in 59.813s (59.813s including waiting). Image size: 10778400361 bytes.
```

The `vllm-soci-br` deployment using SOCI snapshotter's parallel pull/unpack mode implementation on Bottlerocket, results in pull time of **44.974s**.
```sh
> kubectl describe pod -l app=vllm-soci-br | grep Pulled
  Normal   Pulled            9m46s  kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.9-gpu-py312-ec2"
  in 44.974s (44.974s including waiting). Image size: 10778400361 bytes.
```

We can see that using SOCI snapshotter's improved container pull time by about **50%** on Amazon Linux 2023, and about **60%** on Bottlerocket, the reason for that is that Bottlerocket have an improved decompression library for Intel based CPUs ([bottlerocket-core-kit PR #443](https://github.com/bottlerocket-os/bottlerocket-core-kit/pull/443))


## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete -f .
```

