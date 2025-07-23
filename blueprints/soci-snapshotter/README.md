
# Karpenter Blueprint: Using SOCI snapshotter parallel pull/unpack mode

## Purpose

SOCI parallel pull/unpack mode accelerates container image loading through concurrent downloads and decompression, reducing image pull time by up to 50% for large container images.

This optimization is essential when you need complete image availability before container startup but want to eliminate the performance bottleneck of sequential layer downloading. While lazy loading optimizes for immediate startup, parallel pull/unpack mode maximizes throughput during traditional image pulls - making it ideal for batch workloads, AI/ML applications with large images, and high-performance environments where fast, complete image loading is critical.

This blueprint demonstrate how to setup SOCI snapshotter parallel pull/unpack mode on AL2023 by using custom `userData`.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.

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

> ***NOTE***: Both deployments will request instances that have network and ebs bandwidth greater than 8000 Mbps by using `nodeAffinity`
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

The SOCI snapshotter `EC2NodeClass` configuration for setting up SOCI on AL2023 looks like this:

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  ...
  ...
  blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      volumeSize: 100Gi
      volumeType: gp3
      iops: 16000
      throughput: 1000
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