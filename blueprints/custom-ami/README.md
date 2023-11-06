# Karpenter Blueprint: Launching nodes using custom AMIs

## Purpose
When you need to launch nodes using a custom AMI that you've created (i.e. to pre-load base container images), you need to configure an `EC2NodeClass` properly to get the AMI you need. With Karpenter, you might be able to use AMIs for different CPU architectures or other specifications like GPUs. So, our recommendation is that you use a naming convention or a tag to easily identify which AMIs Karpenter can use to launch nodes.

## Requirements

* A custom AMI to use (for this example, we'll skip this requirement)
* An EKS Cluster name with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* An IAM Role name that Karpenter nodes will use

## Deploy

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_INSTANCE_PROFILE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_profile_name)
```

***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN), and `KARPENTER_NODE_IAM_INSTANCE_PROFILE_NAME` is the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html#instance-profiles-manage-console), which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter provisioner. Typically, the instance profile name is the same as the IAM role, but to avoid errors, go to the IAM Console and get the instance profile name assigned to the role (not the ARN).

Now, make sure you're in this blueprint folder, then run the following command:

```
sed -i "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" custom-ami.yaml
sed -i "s/<<KARPENTER_NODE_IAM_INSTANCE_PROFILE_NAME>>/$KARPENTER_NODE_IAM_INSTANCE_PROFILE_NAME/g" custom-ami.yaml
kubectl apply -f .
```

Here's the important configuration block within the spec of an `AWSNodeTemplate`: 

```
  amiSelector:
    aws::name: "*amazon-eks-node-1.27-*"
    aws::owners: self,amazon
```

***IMPORTANT NOTE:*** With this configuration, you're saying that you need to use the latest AMI available for an EKS cluster v1.27 which is either owned by you (customized) or Amazon (official image). We're  using a regular expression to have the flexibility to use AMIs for either `x86` or `Arm`, workloads that need GPUs, or a nodes with different OS like `Windows`. You're basically letting the workload (pod) to decide which type of node(s) it needs. If you don't have a custom AMI created by you in your account, Karpenter will use the official EKS AMI owned by Amazon.

## Results
After waiting for about one minute, you should see a machine ready, and all pods in a `Running` state, like this:

```
❯ kubectl get pods
NAME                         READY   STATUS    RESTARTS   AGE
custom-ami-bdf66b777-2g27q   1/1     Running   0          2m2s
custom-ami-bdf66b777-dbkls   1/1     Running   0          2m2s
custom-ami-bdf66b777-rzlsz   1/1     Running   0          2m2s
❯ kubectl get machines
NAME               TYPE       ZONE         NODE                                        READY   AGE
custom-ami-2ht8b   m5.large   eu-west-1c   ip-10-0-103-91.eu-west-1.compute.internal   True    1m36s
```

## Cleanup
To remove all objects created, simply run the following commands:

```
kubectl delete -f .
```