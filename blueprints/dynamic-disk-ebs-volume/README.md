# Karpenter Blueprint: Dynamic EBS Volume Sizing

## Purpose

This blueprint shows how to automatically resize EBS volumes based on the EC2 instance type that Karpenter provisions. EBS volume size requirements differ among different instance types and this pattern ensures that each node gets an appropriately sized root volume without manual intervention. Some use cases this pattern supports:
* Larger instances host more pods, therefore, it is necessary to have larger EBS volumes to store the corresponding container images. 
* Larger instances host more pods which can make use of ephemeral storage (`emptyDir` volume) therefore, those EBS volumes will need more IOPS to avoid disruptions. 

This blueprint provides configurations for both Amazon Linux 2023 and Bottlerocket operating systems.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* You need to create an [IAM policy](iam-policy.json) and attach it to the IAM Role that Karpenter nodes will use.
* AWS CLI configured with permissions to create and attach IAM policies (`iam:CreatePolicy` and `iam:AttachRolePolicy`), as well as to describe EC2 instances (`ec2:DescribeInstances`) and EBS volumes (`ec2:DescribeVolumes`).

## Deploy

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role (not the ARN).

Now, make sure you're in this blueprint folder. Create the IAM policy required to modify volume size and attach it to the Karpenter node IAM role:

```sh
aws iam attach-role-policy --role-name $KARPENTER_NODE_IAM_ROLE_NAME --policy-arn $(aws iam create-policy --policy-name resizeEBSVolumePolicy --policy-document file://iam-policy.json --query 'Policy.Arn' --output text)
```

Following, there will be separate sections for Amazon Linux 2023 and Bottlerocket. 

<details>

<summary>Amazon Linux 2023</summary>

### Amazon Linux 2023

Deploy the `EC2NodeClass` and `NodePool`:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" al2023.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" al2023.yaml
kubectl apply -f al2023.yaml
```

</details>

<details>

<summary>Bottlerocket</summary>

### Bottlerocket

The Bottlerocket `EC2NodeClass` uses a base64-encoded resize [script](bottlerocket-resize-script.sh) that runs as a bootstrap container to dynamically resize the EBS data volume (`/dev/xvdb`) based on the instance type. The [Bottlerocket bootstrap container](https://github.com/bottlerocket-os/bottlerocket-bootstrap-container) allows to provide our own script to run bootstrap commands to setup our own configuration during runtime. The user-data script needs to be base64 encoded.

The script has to be base64-encoded first and replace in the `EC2NodeClass`. Deploy the `EC2NodeClass` and `NodePool`:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" bottlerocket.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" bottlerocket.yaml
sed -i '' "s/<<BASE64_USER_DATA>>/$(base64 -i bottlerocket-resize-script.sh | tr -d '\n')/" bottlerocket.yaml
kubectl apply -f bottlerocket.yaml
```

</details>

Once you have deployed the `EC2NodeClass` and `Nodepool` for Amazon Linux 2023 or Bottlecket, proceed to deploy the test workload:

```sh
kubectl apply -f workload.yaml
```

## Results

After waiting for about one minute, you should see a machine ready, and all pods in a `Running` state, like this:

```sh
❯ kubectl get pods                                                                          
NAME                                       READY   STATUS    RESTARTS   AGE
dynamic-disk-ebs-volume-6bf87d68f-2ftbq    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-8pnp8    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-ctlvc    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-2ftbq    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-8pnp8    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-ctlvc    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-2ftbq    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-8pnp8    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-ctlvc    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-2ftbq    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-8pnp8    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-ctlvc    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-2ftbq    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-8pnp8    1/1     Running   0          53s
dynamic-disk-ebs-volume-6bf87d68f-ctlvc    1/1     Running   0          53s
❯ kubectl get nodeclaims
NAME            TYPE          ZONE         NODE                                       READY   AGE
default-kpj7k   c6i.2xlarge   eu-west-1b   ip-10-0-73-34.eu-west-1.compute.internal   True    57s
```

To validate that two EBS volumes have been attached to the EC2 instance, you need to run this command:

```sh
aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$(aws ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=dynamic-disk-volume" --query 'Reservations[*].Instances[*].InstanceId' --output text)" --query 'Volumes[*].{VolumeId:VolumeId,Size:Size,InstanceId:Attachments[0].InstanceId,Device:Attachments[0].Device}' --output json
```

The output should be similar to this:

<details>

<summary>Amazon Linux 2023</summary>

### Amazon Linux 2023

```json
[
    {
        "VolumeId": "vol-05e64c3911348a123",
        "Size": 300,
        "InstanceId": "i-00f10439ba9711234",
        "Device": "/dev/xvda"
    },
]
```

For example, if Karpenter provisioned a `c6i.2xlarge` instance, you should see that the /dev/xvda device has been automatically resized to 300GB (as per the sizing logic for 2xlarge instances), even though the initial EBS volume was created with only 20GB.

</details>

<details>

<summary>Bottlerocket</summary>

### Bottlerocket

```json
[
    {
        "VolumeId": "vol-05e64c3911348a123",
        "Size": 4,
        "InstanceId": "i-00f10439ba9711234",
        "Device": "/dev/xvda"
    },
    {
        "VolumeId": "vol-0dafce6a1ada8c123",
        "Size": 300,
        "InstanceId": "i-00f10439ba9711234",
        "Device": "/dev/xvdb"
    }
]
```

For example, if Karpenter provisioned a `c6i.2xlarge` instance, you should see that the /dev/xvdb device has been automatically resized to 300GB (as per the sizing logic for 2xlarge instances), even though the initial EBS volume was created with only 20GB.

</details>

## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete -f .
```