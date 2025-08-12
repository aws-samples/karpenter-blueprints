# Karpenter Blueprint: Dynamic EBS Volume Sizing

## Purpose

This blueprint shows how to automatically resize EBS volumes based on the EC2 instance type that Karpenter provisions. EBS volume size requirements differ among different instance types and this pattern ensures that each node gets an appropriately sized root volume without manual intervention.

This blueprint provides configurations for both Amazon Linux 2023 and Bottlerocket operating systems.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A Karpenter `NodePool` as that's the one we'll use in this blueprint. 
* You need to create an [IAM policy](iam-policy.yaml) and attach it to the role used by Karpenter deployment. 

## Deploy

### Amazon Linux 2023

Deploy the EC2NodeClass and NodePool for Amazon Linux 2023:

```sh
kubectl apply -f al2023.yaml
```

### Bottlerocket

The Bottlerocket nodepool uses a base64-encoded resize script (`bottlerocket-resize-script.sh`) that runs as a bootstrap container to dynamically resize the EBS data volume (`/dev/xvdb`) based on the instance type. 

The script has to be base64-encoded first and replace in the EC2NodeClass. Deploy the EC2NodeClass and NodePool for Bottlerocket:

```sh
sed -i '' "s/<<BASE64_USER_DATA>>/$(base64 -i bottlerocket-resize-script.sh | tr -d '\n')/" bottlerocket.yaml
kubectl apply -f bottlerocket.yaml
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