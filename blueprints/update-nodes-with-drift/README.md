# Karpenter Blueprint: Update Nodes using Drift

## Purpose

After upgrading the Kubernetes control plane version, you might be wondering how to properly upgrade the data plane nodes launched by Karpenter. Currently, Karpenter has a feature gate to mark nodes as drifted. A drifted node is one whose spec and metadata does not match the spec of its `NodePool` and `nodeClassRef`. A node can drift when a user changes their `NodePool` or `nodeClassRef`. Moreover, underlying infrastructure in the nodepool can be changed outside of the cluster. For example, configuring an `amiSelectorTerms` to configure static AMI IDs match the control plane version in the `NodePool`. This allows you to control when to upgrade node's version or when a new AL2 EKS Optimized AMI is released, creating drifted nodes.

Karpenter's drift will reconcile when a node's AMI drifts from `NodePool` requirements. When upgrading a node, Karpenter will minimize the downtime of the applications on the node by initiating `NodePool` logic for a replacement node before terminating drifted nodes. Once Karpenter has begun launching the replacement node, Karpenter will cordon and drain the old node, terminating it when it’s fully drained, then finishing the upgrade.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.

## Deploy

Let's create a new `EC2NodeClass` to be more precise about the AMIs you'd like to use. For now, you'll intentionally create new nodes using a previous EKS version to simulate where you'll be after upgrading the control plane. Within the `amiSelectorTerms` you'll configure the most recent AMIs (both for `amd64` and `arm64`) from a previous version of the control plane to test the drift feature.

```yaml
  amiSelectorTerms:
    - id: <<AMD64PREVAMI>>
    - id: <<ARM64PREVAMI>>
```

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role(not the ARN).

Karpenter will use the latest EKS-optimized AMIs, so when there's a new AMI available or after you update the Kubernetes control plane and you have `Drift` enabled, the nodes with older AMIs are recycled automatically. To test this feature, you need to configure static AMIs within the `EC2NodeClass`. Run the following commands to create an environment variable with the AMI IDs to use:

```sh
export amd64PrevAMI=$(aws ssm get-parameter --name /aws/service/bottlerocket/aws-k8s-1.32/x86_64/latest/image_id --region $AWS_REGION --query "Parameter.Value" --output text)
export arm64PrevAMI=$(aws ssm get-parameter --name /aws/service/bottlerocket/aws-k8s-1.32/arm64/latest/image_id --region $AWS_REGION --query "Parameter.Value" --output text)
```

Now, make sure you're in this blueprint folder, then run the following command to create the new `NodePool` and `EC2NodeClass`:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" latest-current-ami.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" latest-current-ami.yaml
sed -i '' "s/<<AMD64PREVAMI>>/$amd64PrevAMI/g" latest-current-ami.yaml
sed -i '' "s/<<ARM64PREVAMI>>/$arm64PrevAMI/g" latest-current-ami.yaml
kubectl apply -f .
```

## Results

Wait for around two minutes. The pods from the sample workload should be running even if the node has a version that doesn't match with the control plane.

```sh
> kubectl get pods
NAME                                  READY   STATUS    RESTARTS     AGE
latest-current-ami-5bbfbc98f7-6hxkw   1/1     Running   0            3m
latest-current-ami-5bbfbc98f7-n7mgs   1/1     Running   0            3m
latest-current-ami-5bbfbc98f7-rxjjx   1/1     Running   0            3m
```

You should see a new node registered with the latest AMI for EKS `v1.31`, like this:

```sh
> kubectl get nodes -l karpenter.sh/initialized=true
NAME                                         STATUS   ROLES    AGE   VERSION
ip-10-0-103-18.eu-west-2.compute.internal    Ready    <none>   5m6s   v1.31.6-eks-aad632c
```

Let's simulate a node upgrade by changing the EKS version in the `EC2NodeClass`, run this command:

```sh
export amd64LatestAMI=$(aws ssm get-parameter --name /aws/service/bottlerocket/aws-k8s-1.32/x86_64/latest/image_id --region $AWS_REGION --query "Parameter.Value" --output text)
export arm64LatestAMI=$(aws ssm get-parameter --name /aws/service/bottlerocket/aws-k8s-1.32/arm64/latest/image_id --region $AWS_REGION --query "Parameter.Value" --output text)
sed -i '' "s/$amd64PrevAMI/$amd64LatestAMI/g" latest-current-ami.yaml
sed -i '' "s/$arm64PrevAMI/$arm64LatestAMI/g" latest-current-ami.yaml
sed -i '' "s/1.31/1.32/g" latest-current-ami.yaml
kubectl apply -f latest-current-ami.yaml
```

You can confirm the update has been applied by running this command:

```sh
kubectl get ec2nodeclass latest-current-ami -o yaml
```

Wait around five minutes, in the mean time, you can monitor Karpenter logs until you see something like this:

```json
{"level":"INFO","time":"2024-08-16T13:32:10.187Z","logger":"controller","message":"disrupting nodeclaim(s) via replace, terminating 1 nodes (3 pods) ip-10-0-119-175.eu-west-2.compute.internal/c7i-flex.xlarge/spot and replacing with node from types c6a.xlarge, m5.xlarge, c7i-flex.xlarge, m6a.xlarge, c5a.xlarge and 55 other(s)","commit":"5bdf9c3","controller":"disruption","namespace":"","name":"","reconcileID":"be617b33-df37-44fc-897d-737fd3198cee","command-id":"26f7f912-a8f5-4e94-aaaf-386f8da44988","reason":"drifted"}
{"level":"INFO","time":"2024-08-16T13:32:10.222Z","logger":"controller","message":"created nodeclaim","commit":"5bdf9c3","controller":"disruption","namespace":"","name":"","reconcileID":"be617b33-df37-44fc-897d-737fd3198cee","NodePool":{"name":"latest-current-ami"},"NodeClaim":{"name":"latest-current-ami-smlh7"},"requests":{"cpu":"1766m","memory":"1706Mi","pods":"7"},"instance-types":"c4.2xlarge, c4.xlarge, c5.2xlarge, c5.xlarge, c5a.2xlarge and 55 other(s)"}
```

Wait around two minutes. You should now see a new node with the latest AMI version that matches the control plane's version.

```sh
> kubectl get nodes -l karpenter.sh/initialized=true
NAME                                        STATUS   ROLES    AGE   VERSION
ip-10-0-102-231.eu-west-2.compute.internal   Ready    <none>   51s     v1.32.2-eks-677bac1
```

You can repeat this process every time you need to run a controlled upgrade of the nodes. Also, if you'd like to control when to replace a node, you can learn more about [Disruption Budgets](//blueprints/disruption-budgets/).

## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete -f .
```
