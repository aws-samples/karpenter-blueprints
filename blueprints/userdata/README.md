
# Karpenter Blueprint: Customizing nodes with your own User Data automation

## Purpose

When you need to bootstrap the data plane nodes to either overwrite certain Kubernetes settings, mount volumes or anything else you need to do when a node is launched. Within the `EC2NodeClass` there's a `userData` field you can use to control the [user data](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html) that is applied to your worker nodes. This way, you can continue using the [EKS optimized AMI](https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-ami.html) with any additional configuration you need to run on top of the base AMI.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.

## Deploy

You need to create a new `EC2NodeClass` with the `userData` field, along with a `NodePool` to use this new template.

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role(not the ARN).

Now, make sure you're in this blueprint folder, then run the following command to create the new `EC2NodeClass` and `NodePool`:

```
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" userdata.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" userdata.yaml
kubectl apply -f .
```

## Results

The pods from the sample workload should be running:


```
> kubectl get pods
NAME                             READY   STATUS    RESTARTS       AGE
userdata-75d87b5b6c-6s978        1/1     Running   0              45s
userdata-75d87b5b6c-gnglz        1/1     Running   0              45s
userdata-75d87b5b6c-krmxm        1/1     Running   0              45s
```

You can confirm the Kubernetes settings have been added to the user data of the instance by running this command:

```
aws ec2 describe-instance-attribute \
  --instance-id $(aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/nodepool,Values=userdata" \
  --output text --query 'Reservations[0].Instances[0].InstanceId') \
  --attribute userData --query 'UserData.Value' --output text | base64 --decode
```

You should get an output like this with the `[settings.kubernetes]` configured in the `EC2NodeClass`:

```
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
echo "Running a custom user data script"

--//
Content-Type: application/node.eks.aws
```

Look at how the `userdata` from the instance has the `userdata` you specified within the `EC2NodeClass` manifest.

## Cleanup

To remove all objects created, simply run the following commands:

```
kubectl delete -f .
```
