# Karpenter Blueprint: Dynamic EBS Volume Sizing

## Purpose

This blueprint demonstrates how to automatically resize EBS volumes based on the EC2 instance type that Karpenter provisions. Different instance types have varying storage requirements, and this pattern ensures that each node gets an appropriately sized root volume without manual intervention.

The solution uses a custom EC2NodeClass with userData that:
1. Detects the instance type at boot time
2. Calculates the appropriate volume size based on instance size suffix (nano, micro, small, medium, large, xlarge, etc.)
3. Dynamically resizes the EBS volume using AWS CLI
4. Extends the filesystem to use the additional space

This approach is particularly useful for workloads that have different storage requirements based on the compute capacity of the underlying instance.

## Volume Sizing Logic

The blueprint includes intelligent volume sizing based on instance type suffixes:

| Instance Suffix | Volume Size (GB) | Example Instances |
|----------------|------------------|-------------------|
| nano           | 20               | t4g.nano         |
| micro          | 30               | t3.micro, t4g.micro |
| small          | 40               | t3.small, c6i.small |
| medium         | 60               | t3.medium, m5.medium |
| large          | 100              | c5.large, m5.large |
| xlarge         | 200              | c5.xlarge, r5.xlarge |
| 2xlarge        | 300              | c5.2xlarge, m5.2xlarge |
| 3xlarge        | 400              | c5.3xlarge, r5.3xlarge |
| 4xlarge        | 500              | c5.4xlarge, m5.4xlarge |
| 6xlarge        | 600              | c5.6xlarge, r5.6xlarge |
| 8xlarge/9xlarge| 800              | c5.8xlarge, c5.9xlarge |
| 12xlarge       | 1000             | c5.12xlarge, r5.12xlarge |
| 16xlarge/18xlarge | 1200          | c5.16xlarge, r5.18xlarge |
| 24xlarge       | 1500             | c5.24xlarge, r5.24xlarge |
| 32xlarge/48xlarge/56xlarge/112xlarge | 2000 | c5.32xlarge, r5.48xlarge, r5.56xlarge, r5.112xlarge |
| metal          | 1000             | c5.metal, m5.metal |
| *default*      | 100              | Unknown instance sizes |

## Technical Implementation

The dynamic volume resizing is implemented through a bash script in the EC2NodeClass userData that:

### Instance Detection
- Uses IMDSv2 (Instance Metadata Service v2) for secure metadata retrieval
- Extracts instance type, instance ID, and region information
- Implements proper token-based authentication for metadata access

### Volume Sizing Algorithm
- Parses the instance type suffix using `sed` to extract size indicators
- Maps suffixes to appropriate storage sizes using a case statement
- Provides sensible defaults for unknown instance types

### EBS Volume Management
- Queries AWS API to find the root volume ID associated with `/dev/xvda`
- Checks current volume size to avoid unnecessary modifications
- Uses `aws ec2 modify-volume` to resize the EBS volume
- Implements timeout and error handling for volume modification operations

### Filesystem Extension
- Uses `growpart` to extend the partition to use additional space
- Automatically detects filesystem type (XFS or ext4)
- Applies appropriate filesystem resize commands (`xfs_growfs` or `resize2fs`)
- Handles both filesystem types commonly used in Amazon Linux 2023

### Error Handling
- Implements comprehensive error checking at each step
- Continues with normal node bootstrap even if volume resize fails
- Provides detailed logging for troubleshooting

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* The EC2NodeClass includes the necessary IAM permissions for EBS volume modification:
  - `ec2:DescribeInstances`
  - `ec2:DescribeVolumes`
  - `ec2:ModifyVolume`
  - `ec2:DescribeVolumesModifications`

## Deploy

First, deploy the EC2NodeClass and NodePool that includes the dynamic volume sizing logic:

```sh
kubectl apply -f al2023.yaml
```

Then deploy the test workload:

```sh
kubectl apply -f workload.yaml
```

After waiting for around two minutes, notice how Karpenter will provision the machine(s) needed to run the workload:

```sh
> kubectl get nodeclaims
NAME            TYPE          ZONE         NODE                                       READY   AGE
default-kpj7k   c6i.2xlarge   eu-west-1b   ip-10-0-73-34.eu-west-1.compute.internal   True    57s
```

And the workload pods are now running:

```sh
> kubectl get pods                                                                                                             
NAME                                           READY   STATUS    RESTARTS   AGE
dynamic-disk-ebs-volume-foo-6bf87d68f-2ftbq    1/1     Running   0          53s
dynamic-disk-ebs-volume-foo-6bf87d68f-8pnp8    1/1     Running   0          53s
dynamic-disk-ebs-volume-foo-6bf87d68f-ctlvc    1/1     Running   0          53s
```

## Results

You can verify that the EBS volume has been dynamically resized by checking the node's disk space. SSH into the node or use kubectl to check the filesystem size:

```sh
# Get the node name
kubectl get nodes

# Check disk usage on the node
kubectl debug node/<node-name> -it --image=busybox -- df -h
```

For example, if Karpenter provisioned a `c6i.2xlarge` instance, you should see that the root volume has been automatically resized to 300GB (as per the sizing logic for 2xlarge instances), even though the initial EBS volume was created with only 20GB.

The userData script in the EC2NodeClass handles:
- Detecting the instance type using IMDSv2
- Calculating the target volume size based on the instance suffix
- Modifying the EBS volume using AWS CLI
- Waiting for the modification to complete
- Extending the partition and filesystem to use the additional space
- Supporting both XFS and ext4 filesystems

This ensures that each node gets storage capacity appropriate for its compute capacity without manual intervention.

## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete -f .
```
