# Karpenter Blueprint: Using multiple EBS volumes

## Purpose
This blueprint shows how to attach more than one EBS volume to a data plane node. Maybe you need to use a volume for logs, cache, or any container resources such as images. You do this configuration in the `AWSNodeTemplate`, then you configure a `Provisioner` to use such template when launching a machine. 

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* An IAM Role name that Karpenter nodes will use
* AWS CLI configured with permissions to describe EC2 instances (`ec2:DescribeInstances`)

## Deploy

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_INSTANCE_PROFILE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_profile_name)
```

***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN), and `KARPENTER_NODE_IAM_INSTANCE_PROFILE_NAME` is the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html#instance-profiles-manage-console), which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter provisioner. Typically, the instance profile name is the same as the IAM role, but to avoid errors, go to the IAM Console and get the instance profile name assigned to the role (not the ARN).

Now, make sure you're in this blueprint folder, then run the following command:

```
sed -i "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" multi-ebs.yaml
sed -i "s/<<KARPENTER_NODE_IAM_INSTANCE_PROFILE_NAME>>/$KARPENTER_NODE_IAM_INSTANCE_PROFILE_NAME/g" multi-ebs.yaml
kubectl apply -f .
```

Here's the important configuration block within the spec of an `AWSNodeTemplate`: 

```
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

```
❯ kubectl get pods                                                                                                             1m 52s
NAME                        READY   STATUS    RESTARTS   AGE
multi-ebs-f4fb69fdd-kstj9   1/1     Running   0          2m34s
multi-ebs-f4fb69fdd-t9xnl   1/1     Running   0          2m34s
multi-ebs-f4fb69fdd-x42ss   1/1     Running   0          2m34s
❯ kubectl get machines
NAME              TYPE        ZONE         NODE                                       READY   AGE
multi-ebs-chvzv   m5.xlarge   eu-west-1a   ip-10-0-43-92.eu-west-1.compute.internal   True    3m55s
```

To validate that two EBS volumes have been attached to the EC2 instance, you need to run this command:

```
aws ec2 describe-instances --filters "Name=tag:karpenter.sh/provisioner-name,Values=multi-ebs" --query 'Reservations[*].Instances[*].{Instance:InstanceId,Instance:BlockDeviceMappings}' --output json
```

The output should be similar to this:

```
[
    [
        {
            "Instance": [
                {
                    "DeviceName": "/dev/xvda",
                    "Ebs": {
                        "AttachTime": "2023-09-08T12:32:46+00:00",
                        "DeleteOnTermination": true,
                        "Status": "attached",
                        "VolumeId": "vol-05d723169c01028d1"
                    }
                },
                {
                    "DeviceName": "/dev/xvdb",
                    "Ebs": {
                        "AttachTime": "2023-09-08T12:32:46+00:00",
                        "DeleteOnTermination": true,
                        "Status": "attached",
                        "VolumeId": "vol-0af5ebb6cc0ba5c11"
                    }
                }
            ]
        }
    ]
]
```

## Cleanup
To remove all objects created, simply run the following commands:

```
kubectl delete -f .
```