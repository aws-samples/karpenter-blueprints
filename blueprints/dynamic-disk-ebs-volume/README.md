# Karpenter Blueprint: Dynamic EBS Volume Sizing

## Purpose

When Karpenter provisions nodes of varying sizes, EBS volume capacity becomes a critical constraint. Consider a scenario where 10 pods require substantial storage for multiple container images and ephemeral data—if Karpenter launches a mix of instance types (2xlarge, 4xlarge, 6xlarge), a fixed 20GB root volume will fail on larger instances that need to store more container images and handle higher pod density. With the rise of AI/ML workloads on Kubernetes, the growth in container image sizes has been considerably, where image are commonly ten of gigabytes in size; these images will demand big instance types along with suitable allocated disk space. 

This blueprint automatically resizes EBS volumes based on instance type: a c6i.2xlarge receives 300GB, a c6i.4xlarge gets 500GB, and a c6i.6xlarge provisions 600GB—eliminating manual intervention and preventing storage-related disruptions. 

Key use cases include:

* AI/ML workloads where images demand considerable disk space. 
* Larger instances hosting more pods require proportionally larger EBS volumes to store the corresponding container images.
* Larger instances hosting pods that utilize ephemeral storage (emptyDir volumes) need EBS volumes with higher IOPS to prevent I/O bottlenecks.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* AWS CLI configured with permissions to create and attach IAM policies (`iam:CreatePolicy` and `iam:AttachRolePolicy`), as well as to describe EC2 instances (`ec2:DescribeInstances`) and EBS volumes (`ec2:DescribeVolumes`).

## Deploy

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role (not the ARN).

The Karpenter node IAM role needs additional permissions to allow the bootstrap script to expand EBS volume sizes. Let's create an IAM policy with the required permissions and attach it to the Karpenter node IAM role:

```sh
aws iam attach-role-policy --role-name $KARPENTER_NODE_IAM_ROLE_NAME --policy-arn $(aws iam create-policy --policy-name resizeEBSVolumePolicy --policy-document file://iam-policy.json --query 'Policy.Arn' --output text)
```

Now, make sure you're in this blueprint folder, then run the following command:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" ebs-dynamic-resize.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" ebs-dynamic-resize.yaml
kubectl apply -f .
```

> ***NOTE***: It can take a couple of minutes for resource to be created, while resources are being created you can continue reading.

Those commands creates the following:
1. `EC2NodeClass` and `NodePool` named `ebs-dynamic-resize` for enabling the dynamic resize of EBS according to instance size on Amazon Linux 2023.
2. Kubernetes `Deployment` named `vllm-ebs-dynamic-resize` that uses the `ebs-dynamic-resize` `NodePool`

> ***NOTE***: For our example, the deployment uses [SOCI-Seekable OCI](https://github.com/awslabs/soci-snapshotter) parallel mode capabilities; therefore, it request instances that have network and ebs bandwidth greater than 8000 Mbps by using `nodeAffinity` in order to eliminate network and storage I/O bottlenecks.
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

## Results

Wait until the pods from the sample workload are in running status:

```sh
> kubectl wait --for=condition=Ready pods --all --namespace default --timeout=500s
pod/vllm-ebs-dynamic-resize-9b558b46-87nm2 condition met
pod/vllm-ebs-dynamic-resize-9b558b46-9n58b condition met
pod/vllm-ebs-dynamic-resize-9b558b46-vtdvt condition met
```

The sample workload deploys one Deployments with three replicas running [Amazon Deep Learning Container (DLC) for vLLM](https://docs.aws.amazon.com/deep-learning-containers/latest/devguide/dlc-vllm-x86-ec2.html). The Amazon DLC for vLLM container image size is about **~10GB** which will not fit on the base EC2NodeClass that has a 20Gi volume size. 

Let's examine the EBS volume resized for each instance, you need to run this command:

```sh
aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$(aws ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=ebs-dynamic-resize" --query 'Reservations[*].Instances[*].InstanceId' --output text | tr '\n' ',' | sed 's/,$//')" --query 'Volumes[*].{VolumeId:VolumeId,Size:Size,InstanceId:Attachments[0].InstanceId,Device:Attachments.Device}' --output json
```

The output should be similar to this:

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

The volume size in the NodePool was set to 20Gi and it was dynamically set to 300Gi based on the instance type. 

## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete -f .
```

## Bottlerocket

In case you want to use this blueprint with Bottlerocket instances, the resize bash script must be passed via a [bootstrap container](https://github.com/bottlerocket-os/bottlerocket-bootstrap-container). The user-data script needs to be base64 encoded. 
```
  userData: |
    [settings.bootstrap-containers.ebsresize]
    mode = "once"
    user-data = "<<BASE64_USER_DATA>>"
```
The script used in this blueprint for an Amazon Linux 2023 instance can be base64-encoded as it is and it will work.