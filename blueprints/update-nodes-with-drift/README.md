# Karpenter Blueprint: Update Nodes using Drift

## Purpose
After upgrading the Kubernetes control plane version, you might be wondering how to properly upgrade the data plane nodes launched by Karpenter. Currently, Karpenter has a feature gate to mark nodes as drifted. A drifted node is one whose spec and metadata does not match the spec of its `NodePool` and `nodeClassRef`. A node can drift when a user changes their `NodePool` or `nodeClassRef`. Moreover, underlying infrastructure in the nodepool can be changed outside of the cluster. For example, configuring an `amiSelectorTerms` to match the control plane version in the `NodePool`. This allows you to control when to upgrade node's version or when a new AL2 EKS Optimized AMI is released, creating drifted nodes.

Karpenter's drift will reconcile when a node's AMI drifts from provisioning requirements. When upgrading a node, Karpenter will minimize the downtime of the applications on the node by initiating provisioning logic for a replacement node before terminating drifted nodes. Once Karpenter has begun provisioning the replacement node, Karpenter will cordon and drain the old node, terminating it when it’s fully drained, then finishing the upgrade.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.

## Deploy
Let's start by enabling the [drift](https://karpenter.sh/docs/concepts/disruption/#drift) feature gate in Karpenter's deployment environment variable. To do so, run this command:

```
kubectl -n karpenter get deployment karpenter -o yaml | \
  sed -e 's|Drift=false|Drift=true|' | \
  kubectl apply -f -
```

**NOTE:** You might get this message: `Warning: resource deployments/karpenter is missing the kubectl.kubernetes.io/last-applied-configuration annotation which is required by kubectl apply`. Your change will be applied, this warning appears the first time to inform you that the resource might be managed by something else. This annotation will get added and you won't see the warning going forward.

You can confirm the configuration has been updated running the following command:

```
kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env}' | grep Drift
```

Now, you can confirm that the Karpenter pods have been recreated:

```
❯ kubectl get pods -n karpenter
NAME                         READY   STATUS    RESTARTS   AGE
karpenter-7c6f4995bf-7dg5r   1/1     Running   0          2m34s
karpenter-7c6f4995bf-82ttb   1/1     Running   0          2m34s
```

Once drift is enabled, let's create a new `EC2NodeClass` to be more precise about the AMIs you'd like to use. For now, you'll intentionally create new nodes using a previous EKS version to simulate where you'll be after upgrading the control plane. 

```
  amiSelectorTerms:
  - name: '*-1.27-*' # Will get the latest AMI of this Kubernetes version
    owner: self
  - name: '*-1.27-*' # Will get the latest AMI of this Kubernetes version
    owner: amazon
```

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/). which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role(not the ARN).


Now, make sure you're in this blueprint folder, then run the following command to create the new `NodePool` and `EC2NodeClass`:

```
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" latest-current-ami.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" latest-current-ami.yaml
kubectl apply -f .
```

## Results

Wait for around two minutes. The pods from the sample workload should be running even if the node has a version that doesn't match with the control plane.

```
> kubectl get pods
NAME                                  READY   STATUS    RESTARTS     AGE
latest-current-ami-5bbfbc98f7-6hxkw   1/1     Running   0            3m
latest-current-ami-5bbfbc98f7-n7mgs   1/1     Running   0            3m
latest-current-ami-5bbfbc98f7-rxjjx   1/1     Running   0            3m
```

You should see a new node registered with the latest AMI for EKS `v1.27`, like this:

```
> kubectl get nodes -l karpenter.sh/initialized=true
NAME                                        STATUS   ROLES    AGE     VERSION
ip-10-0-48-23.eu-west-1.compute.internal    Ready    <none>   6m28s   v1.27.4-eks-8ccc7ba
```

Let's simulate a node upgrade by changing the EKS version in the `EC2NodeClass`, run this command:

```
kubectl -n karpenter get ec2nodeclass latest-current-ami-template -o yaml | \
  sed -e 's|1.27|1.28|' | \
  kubectl apply -f -
```

You can confirm the update has been applied by running this command:

```
kubectl get ec2nodeclass latest-current-ami-template -o yaml
```

Wait around two minutes, in the mean time, you can monitor Karpenter logs until you see something like this:

```
2023-09-13T16:54:21.200Z	DEBUG	controller.machine.disruption	marking machine as drifted	{"commit": "34d50bf-dirty", "machine": "latest-current-ami-p25g5"}
2023-09-13T16:54:31.151Z	INFO	controller.deprovisioning	deprovisioning via drift replace, terminating 1 machines ip-10-0-48-23.eu-west-1.compute.internal/m5.xlarge/spot and replacing with machine from types c6in.xlarge, r6id.2xlarge, r7a.xlarge, m5dn.12xlarge, m7i.16xlarge and 261 other(s)	{"commit": "34d50bf-dirty"}
```

You should now see a new node with the latest AMI version that matches the control plane's version.

```
> kubectl get nodes -l karpenter.sh/initialized=true
NAME                                        STATUS   ROLES    AGE   VERSION
ip-10-0-60-27.eu-west-1.compute.internal    Ready    <none>   20s   v1.28.3-eks-8ccc7ba
```

You can repeat this process every time you need to run a controlled upgrade of the nodes.

## Cleanup
To remove all objects created, simply run the following commands:

```
kubectl delete -f .
```