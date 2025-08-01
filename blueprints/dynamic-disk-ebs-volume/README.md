# Karpenter Blueprint: Dynamic EBS Volume Sizing

## Purpose

This blueprint shows how to automatically resize EBS volumes based on the EC2 instance type that Karpenter provisions. EBS volume size requirements differ among different instance types and this pattern ensures that each node gets an appropriately sized root volume without manual intervention.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter `NodePool` as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.
* You need to create an [IAM policy](iam-policy.yaml) and attach it to the role used by Karpenter deployment. 

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
dynamic-disk-ebs-volume-foo-6bf87d68f-2ftbq    1/1     Running   0          53s
dynamic-disk-ebs-volume-foo-6bf87d68f-8pnp8    1/1     Running   0          53s
dynamic-disk-ebs-volume-foo-6bf87d68f-ctlvc    1/1     Running   0          53s
dynamic-disk-ebs-volume-foo-6bf87d68f-2ftbq    1/1     Running   0          53s
dynamic-disk-ebs-volume-foo-6bf87d68f-8pnp8    1/1     Running   0          53s
dynamic-disk-ebs-volume-foo-6bf87d68f-ctlvc    1/1     Running   0          53s
dynamic-disk-ebs-volume-foo-6bf87d68f-2ftbq    1/1     Running   0          53s
dynamic-disk-ebs-volume-foo-6bf87d68f-8pnp8    1/1     Running   0          53s
dynamic-disk-ebs-volume-foo-6bf87d68f-ctlvc    1/1     Running   0          53s
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
kubectl debug node/<node-name> -it --image=busybox -- df -hT
```

For example, if Karpenter provisioned a `c6i.2xlarge` instance, you should see that the root volume has been automatically resized to 300GB (as per the sizing logic for 2xlarge instances), even though the initial EBS volume was created with only 20GB.

## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete -f .
```