
# Karpenter Blueprint: Using SOCI snapshotter parallel pull/unpack mode

## Purpose

Container image pull performance has become a bottleneck as container images grow larger, compared to when typical images were just a few hundred megabytes.
The default pulling method uses sequential layer downloading and unpacking. SOCI parallel pull/unpack mode accelerates container image loading through concurrent downloads and unpacking operations, reducing image pull time by up to 50%. This makes it ideal for AI/ML and Batch workloads, where it is common for those applications to have a large container images.

This blueprint demonstrate how to setup SOCI snapshotter parallel pull/unpack mode on AL2023 through a custom `EC2NodeClass` and customizing the `userData` field.

> ***NOTE***: In this example we demonstrate SOCI snapshotter on Amazon Linux 2023 (AL2023), SOCI snapshotter is not currently supported on Bottlerocket. While SOCI snapshotter can be supported on other distros, we use this example on AL2023 that uses `NodeConfig` to simplify the customization of `containerd` and `kubelet` configuration. If you would like to setup on other distros, you can use the installation script provided in the example but you will have to customize `containerd` and `kubelet` configuration yourself.

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

Those commands created the following:
1. `EC2NodeClass` and `NodePool` named `soci-snapshotter` for using SOCI snapshotter parallel pull/unpack mode with customized `blockDeviceMappings` for increased I/O and storage size.
2. `EC2NodeClass` and `NodePool` named `non-soci-snapshotter` for using default containerd implementation with customized `blockDeviceMappings` for increased I/O and storage size.
3. Kubernetes `Deployment` named `vllm` that uses the `non-soci-snapshotter` `NodePool`
4. Kubernetes `Deployment` named `vllm-soci` that uses the `soci-snapshotter` `NodePool`

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
The example configure the root volume with IOPs of 16,000 and throughput of 1,000Mbps which is the maximum for GP3, it is recommended that you modify those settings accordingly to trade-off between performance and cost.

We also set the `instanceStorePolicy: RAID0` field, that will utilize instance store NVMe disks, in case of multiple disks, it will stripe them as RAID0, mount them, and make sure containerd root dir is used on those disks.
If the `EC2NodeClass` is being used with `NodePool` that only launch instances with instance store, the `blockDeviceMappings` can be removed to reduce cost, as SOCI snapshotter root dir is configured to use containerd root dir and will utilize instance store which are high performant NVMe disks.

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
      iops: 16000
      throughput: 1000
  instanceStorePolicy: RAID0
...
...
```
The `userData` field is used to initiate the SOCI snapshotter setup and to configure containerd and kubelet.

SOCI parallel mode configuration is controlled by several key settings. While the default values align with containerd's standard configuration to ensure stability and safety, you can adjust these parameters to optimize performance based on your specific needs, but ensure the infastructure can support it.

1. `max_concurrent_downloads_per_image`: Limits the maximum concurrent downloads per individual image, Default is 3. For images hosted on Amazon ECR we recommend setting this to 10-20.
2. `max_concurrent_unpacks_per_image`: Sets the limit for concurrent unpacking of layers per image. Default is 1. Tuning this to match the number of avg layers count of your container images.
3. `soci_root_dir`: where downloaded data is stored and extracted, this path should be backed by an high performance storage subsystem. Default is "/var/lib/soci-snapshotter-grpc". We have set this under /var/lib/containerd where containerd data is stored to benefit when using `instanceStorePolicy: RAID0`.

The second part of the `userData` handles the configuration of containerd and kubelet through [`NodeConfig`](https://awslabs.github.io/amazon-eks-ami/nodeadm/) which is only supported on AL2023 and simplify various data plane configurations.

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

## Results

Wait until the pods from the sample workload are in running status:
```sh
> kubectl wait --for=condition=Ready pods --all --namespace default --timeout=300s
pod/vllm-85b4fbdd49-k88gg condition met
pod/vllm-soci-744dfdbcfb-d4bwj condition met
```

The sample workload deploys two Deployments running [Amazon Deep Learning Containers for vLLM](https://docs.aws.amazon.com/deep-learning-containers/latest/devguide/dlc-vllm-x86-ec2.html), one using SOCI parallel pull/unpack mode and one remains using the default containerd implementation.

Let's examine the pull time for each Deployment:

The `vllm` deployment using the default containerd implementation results in pull time of **2m18.049s**.
```sh
> kubectl describe pod/vllm-85b4fbdd49-k88gg | grep Pulled
  Normal   Pulled            3m43s  kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.9-gpu-py312-ec2" in 2m18.049s (2m18.049s including waiting). Image size: 10757041023 bytes.
```

The `vllm-soci` deployment using SOCI snapshotter's parallel pull/unpack mode implementation results in pull time of **1m7.272s**.
```sh
> kubectl describe pod/vllm-soci-744dfdbcfb-d4bwj | grep Pulled
  Normal   Pulled            5m40s  kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.9-gpu-py312-ec2" in 1m7.272s (1m7.272s including waiting). Image size: 10757041023 bytes.
```

We can see that using SOCI snapshotter's improved container pull time by about **50%**.

## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete -f .
```