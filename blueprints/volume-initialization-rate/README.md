# Karpenter Blueprint: Working with EBS Volume Initialization Rates

## Purpose
The `volumeInitializationRate` parameter in Amazon EBS allows you to control the speed at which snapshot data is downloaded from Amazon S3 to a new volume. This rate (between 100-300 MiB/s) determines how quickly your volume becomes fully initialized. The initialization time depends on two key factors:
- The actual snapshot data size (not the volume size)
- Your specified initialization rate

For example:
- With a 10 GiB snapshot and 300 MiB/s rate, initialization takes ~34.1 seconds
- Creating multiple volumes from the same snapshot with the same rate will complete in parallel
- The rate applies to the data transfer from S3, regardless of final volume size

***NOTE:** You can specify a [Volume Initialization Rates](https://docs.aws.amazon.com/ebs/latest/userguide/initalize-volume.html)  rate of between 100 and 300 MiB/s.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter `NodePool` as that's the one we'll use in this blueprint.
* The [Amazon EBS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/managing-ebs-csi.html) installed in the cluster.
* Appropriate IAM permissions for EBS operations.
* For this demo AWS CLI with ec2 create c,,,,,

## Configure
We configure the `volumeInitializationRate` within the EC2NodeClass to use within the `blockDeviceMappings`.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        volumeInitializationRate: 300  
```

## Configure Snapshot
Let's start by creating the `ebs volume` and `snapshot` of `10gb`. To do so, run this command to get create the resources automatically:

```
export FIRSTAZ=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)
VOLUME_ID=$(aws ec2 create-volume \
    --volume-type gp3 \
    --size 10 \
    --availability-zone $FIRSTAZ \
    --query 'VolumeId' \
    --output text)

SNAPSHOT_ID=$(aws ec2 create-snapshot \
    --volume-id $VOLUME_ID \
    --description "Test snapshot for initialization rate demo" \
    --query 'SnapshotId' \
    --output text)

aws ec2 wait snapshot-completed --snapshot-ids $SNAPSHOT_ID
```

We can check the status of the snapshot with the following command:

```
aws ec2 describe-snapshots \
    --snapshot-ids $SNAPSHOT_ID \
    --query 'Snapshots[0].[SnapshotId,VolumeSize,Description]' \
    --output table
```

You shoud see an ouput similar to:

```
------------------------------------------------
|               DescribeSnapshots              |
+----------------------------------------------+
|  snap-0d6af603dbe1da520                      |
|  10                                         |
|  Test snapshot for initialization rate demo  |
+----------------------------------------------+
```

1. Let's demonstrate this using EC2NodeClass with different initialization rates:

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: slow
spec:
  amiFamily: Bottlerocket
  amiSelectorTerms: 
  - alias: bottlerocket@latest
  blockDeviceMappings:
  - deviceName: /dev/xvdc 
    ebs:
      deleteOnTermination: true
      volumeSize: 10Gi
      volumeType: gp3
      volumeInitializationRate: 100
      snapshotID: "snap-XXXXXXXX"

---

apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: fast
spec:
  amiFamily: Bottlerocket
  amiSelectorTerms: 
  - alias: bottlerocket@latest
  blockDeviceMappings:
  - deviceName: /dev/xvdc 
    ebs:
      deleteOnTermination: true
      volumeSize: 10Gi
      volumeType: gp3
      volumeInitializationRate: 300
      snapshotID: "snap-XXXXXXXX"
```

## Configure Snapshot
Let's start by creating the `ebs volume` and `snapshot` of `10gb`. To do so, run this command to get create the resources automatically:

Now, make sure you're in this blueprint folder, then run the following command:

```
  sed -i '' "s/<<SNAPSHOT_ID>>/$SNAPSHOT_ID/g" volume-initialization-rate.yml
  sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" volume-initialization-rate.yml
  sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" volume-initialization-rate.yml
  k apply -f volume-initialization-rate.yml 
```

## Results
After waiting for about one minute, you should see a machine ready, and all pods in a `Running` state, like this:

```
nodepool.karpenter.sh/fast-initialization created
nodepool.karpenter.sh/slow-initialization created
ec2nodeclass.karpenter.k8s.aws/fast created
ec2nodeclass.karpenter.k8s.aws/slow created
deployment.apps/fast-nginx created
deployment.apps/slow-nginx created

k get pods
NAME                          READY   STATUS    RESTARTS   AGE
fast-nginx-6476bf8547-b2jc8   1/1     Running   0          2m59s
slow-nginx-5f5976b596-tfln9   1/1     Running   0          2m59s
```

    
k get ec2nodeclass                                                                                 
NAME        READY   AGE
default     True    5h10m
fast        True    58s
slow        True    58s



TODO:

- Add permission guide for role 
```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "ec2:RunInstances",
            "Resource": [
                "arn:aws:ec2:eu-west-2::snapshot/*"
            ]
        }
    ]
}
``` 

- Add demo of how to see the calculated value with log or metric