# Karpenter Blueprint: Using multiple EBS volumes

## Purpose

This blueprint shows how to attach more than one EBS volume to a data plane node. Maybe you need to use a volume for logs, cache, or any container resources such as images. You do this configuration in the `EC2NodeClass`, then you configure a `NodePool` to use such template when launching a machine.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* An IAM Role name that Karpenter nodes will use
* AWS CLI configured with permissions to describe EC2 instances (`ec2:DescribeInstances`)

## Deploy

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role (not the ARN).

Now, make sure you're in this blueprint folder, then run the following command:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" multi-ebs.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" multi-ebs.yaml
kubectl apply -f .
```

Here's the important configuration block within the spec of an `EC2NodeClass`:

```yaml
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeType: gp3
        volumeSize: 20
        deleteOnTermination: true
    - deviceName: /dev/xvdb
      ebs:
        volumeType: gp3
        volumeSize: 100Gi
        deleteOnTermination: true
```

## Results

After waiting for about one minute, you should see a machine ready, and all pods in a `Running` state, like this:

```sh
❯ kubectl get pods                                                                                                             1m 52s
NAME                        READY   STATUS    RESTARTS   AGE
multi-ebs-f4fb69fdd-kstj9   1/1     Running   0          2m34s
multi-ebs-f4fb69fdd-t9xnl   1/1     Running   0          2m34s
multi-ebs-f4fb69fdd-x42ss   1/1     Running   0          2m34s
❯ kubectl get nodeclaims
NAME              TYPE        ZONE         NODE                                       READY   AGE
multi-ebs-chvzv   m5.xlarge   eu-west-1a   ip-10-0-43-92.eu-west-1.compute.internal   True    3m55s
```

To validate that two EBS volumes have been attached to the EC2 instance, you need to run this command:

```sh
aws ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=multi-ebs" --query 'Reservations[*].Instances[*].{Instance:InstanceId,Instance:BlockDeviceMappings}' --output json
```

The output should be similar to this:

```json
[
    [
        {
            "Instance": [
                {
                    "DeviceName": "/dev/xvda",
                    "Ebs": {
                        "AttachTime": "2024-08-16T12:39:36+00:00",
                        "DeleteOnTermination": true,
                        "Status": "attached",
                        "VolumeId": "vol-0561b68b188d4e63a"
                    }
                },
                {
                    "DeviceName": "/dev/xvdb",
                    "Ebs": {
                        "AttachTime": "2024-08-16T12:39:36+00:00",
                        "DeleteOnTermination": true,
                        "Status": "attached",
                        "VolumeId": "vol-0ca5ca8b749f6bed0"
                    }
                }
            ]
        }
    ]
]
```

## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete -f .
```
