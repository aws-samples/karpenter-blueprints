# Karpenter Blueprint: Dynamic EBS Volume Sizing

## Purpose

When Karpenter provisions nodes of varying sizes, EBS volume capacity becomes a critical constraint. A fixed 20GB root volume fails on larger instances that need to store more container images and handle higher pod density.

Consider a scenario where 10 pods require substantial storage for multiple container images and ephemeral data. If Karpenter launches a mix of instance types (2xlarge, 4xlarge, 6xlarge), the fixed volume size becomes a bottleneck. This problem has intensified with AI/ML workloads on Kubernetes, where container images are commonly tens of gigabytes in size and demand larger instance types with suitable disk space.

This blueprint automatically resizes EBS volumes based on instance type: a c6i.2xlarge receives 300GB, a c6i.4xlarge gets 500GB, and a c6i.6xlarge provisions 600GB—eliminating manual intervention and preventing storage-related disruptions.

**Key use cases:**

* AI/ML workloads with large container images requiring considerable disk space
* Larger instances hosting more pods that need proportionally larger EBS volumes to store container images
* Larger instances with pods using ephemeral storage (emptyDir volumes) that require higher IOPS to prevent I/O bottlenecks

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* AWS CLI configured with permissions to create and attach IAM policies (`iam:CreatePolicy` and `iam:AttachRolePolicy`), as well as to describe EC2 instances (`ec2:DescribeInstances`) and EBS volumes (`ec2:DescribeVolumes`).

## Deploy

### 1. Set Environment Variables

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:
```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

**If not using Terraform**, set these variables manually:
- `CLUSTER_NAME`: Your EKS cluster name (not the ARN)
- `KARPENTER_NODE_IAM_ROLE_NAME`: The IAM role name (not ARN) used in your EC2NodeClass `spec.role` field

> Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) from the role specified in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/). Typically, the instance profile name matches the IAM role name.

### 2. Attach IAM Policy

The Karpenter node IAM role needs additional permissions to allow the bootstrap script to expand EBS volume sizes. Create and attach the required IAM policy:
```sh
aws iam attach-role-policy \
 --role-name $KARPENTER_NODE_IAM_ROLE_NAME \
 --policy-arn $(aws iam create-policy \
   --policy-name resizeEBSVolumePolicy \
   --policy-document file://iam-policy.json \
   --query 'Policy.Arn' \
   --output text)
```

### 3. Deploy Resources

Make sure you're in this blueprint folder, then apply the configuration:
```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" ebs-dynamic-resize.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" ebs-dynamic-resize.yaml
kubectl apply -f ebs-dynamic-resize.yaml -f deployment.yaml
```

> **Note**: Resource creation takes a couple of minutes. You can continue reading while resources are being created.

This creates the following resources:

1. **EC2NodeClass and NodePool** (`ebs-dynamic-resize`): Enables dynamic EBS resizing based on instance size using Amazon Linux 2023
2. **Kubernetes Deployment** (`vllm-ebs-dynamic-resize`): Sample workload that uses the `ebs-dynamic-resize` NodePool

### Instance Selection

The sample deployment uses [SOCI (Seekable OCI)](https://github.com/awslabs/soci-snapshotter) parallel mode capabilities and requires instances with sufficient network and EBS bandwidth. It uses `nodeAffinity` to select instances with both network and EBS bandwidth greater than 8000 Mbps to eliminate I/O bottlenecks:
```yaml
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

## Results

Let's verify that the EBS volumes were dynamically resized based on the instance types provisioned by Karpenter.

First, wait until the pods from the sample workload are running:
```sh
> kubectl wait --for=condition=Ready pods --all --namespace default --timeout=360s
```

Expected output:
```sh
pod/vllm-ebs-dynamic-resize-9b558b46-87nm2 condition met
pod/vllm-ebs-dynamic-resize-9b558b46-9n58b condition met
pod/vllm-ebs-dynamic-resize-9b558b46-vtdvt condition met
```

The sample workload deploys one Deployment with three replicas running the [Amazon Deep Learning Container (DLC) for vLLM](https://docs.aws.amazon.com/deep-learning-containers/latest/devguide/dlc-vllm-x86-ec2.html). This container image is approximately 10GB, which exceeds the base EC2NodeClass volume size of 20Gi.

Now, examine the resized EBS volumes for the provisioned instances:
```sh
aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$(aws ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=ebs-dynamic-resize" --query 'Reservations[*].Instances[*].InstanceId' --output text | tr '\n' ',' | sed 's/,$//')" --query 'Volumes[*].{VolumeId:VolumeId,Size:Size,InstanceId:Attachments[0].InstanceId,Device:Attachments.Device}' --output json
```

Expected output:
```json
[
    {
        "VolumeId": "vol-068293cd6f4cb088d",
        "Size": 300,
        "InstanceId": "i-008e495fd7e5324f0",
        "Device": /dev/xvda
    }
]
```

Notice that the volume size was dynamically increased from the NodePool's configured 20Gi to 300Gi based on the instance type provisioned.

## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete f ebs-dynamic-resize.yaml -f deployment.yaml
```

## Instances with ephemeral storage

This script does not resize EBS volumes when the instance has ephemeral storage, since it is better suited for storing container images, ephemeral data, and logs.

The following parameter in the NodePool sets up a RAID-0 XFS filesystem from any NVMe instance storage disks, moves the contents of `/var/lib/kubelet`, `/var/log/pods`, and `/var/lib/containerd` to the new RAID, and symlinks those directories back to the root filesystem:
```yaml
  instanceStorePolicy: RAID0
```

If this parameter is not set in your NodePool, you must manually configure `/var/lib/kubelet`, `/var/log/pods`, and `/var/lib/containerd` to use the ephemeral storage.

## Bottlerocket

If you want to use Bottlerocket OS instead of Amazon Linux 2023, the resize script must be delivered differently due to Bottlerocket's immutable design.

The script needs to be passed via a [bootstrap container](https://github.com/bottlerocket-os/bottlerocket-bootstrap-container) and base64-encoded in the user-data configuration:
```yaml
  userData: |
    [settings.bootstrap-containers.ebsresize]
    mode = "once"
    user-data = "<<BASE64_USER_DATA>>"
```

The same bash script used for Amazon Linux 2023 instances in this blueprint can be base64-encoded as-is and will work with Bottlerocket.

To encode the script:
```sh
cat resize-script.sh | base64 | tr -d '\n'
```
Then replace `<<BASE64_USER_DATA>>` with the encoded output.