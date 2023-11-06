# Karpenter Blueprints for Amazon EKS

## Motivation
[Karpenter](https://karpenter.sh/), a node provisioning project built for Kubernetes has been helping many companies to improve the efficiency and cost of running workloads on Kubernetes. However, as Karpenter takes an application-first approach to provision compute capacity for the Kubernetes data plane, there are common workload scenarios that you might be wondering how to configure them properly. This repository includes a list of common workload scenarios, some of them go in depth with the explanation of why configuring Karpenter and Kubernetes objects in such a way is important.

## Blueprint Structure
Each blueprint follows the same structure to help you better understand what's the motivation and the expected results:

| Concept        | Description                                                                                     |
| -------------- | ----------------------------------------------------------------------------------------------- |
| Purpose        | Explains what the blueprint is about, and what problem is solving.                              |
| Requirements   | Any pre-requisites you might need to use the blueprint (i.e. An `arm64` container image).       |
| Deploy         | The steps to follow to deploy the blueprint into an existing Kubernetes cluster.                |
| Results        | The expected results when using the blueprint.                                                  |

## How to use these Blueprints?
Before you get started, you need to have a Kubernetes cluster with Karpenter installed. If you're planning to work with an existing cluster, just make sure you've configured Karpenter following the [official guide](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/). This project also has a template to create a cluster with everything you'll need to test each blueprint.

### Requirements

* You need access to an AWS account with IAM permissions to create an EKS cluster, and an AWS Cloud9 environment if you're running the commands listed in this tutorial.
* Install and configure the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* Install the [Kubernetes CLI (kubectl)](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
* (Optional*) Install the [Terraform CLI](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
* (Optional*) Install Helm ([the package manager for Kubernetes](https://helm.sh/docs/intro/install/))

***NOTE:** If you're planning to use an existing EKS cluster, you don't need the **optional** prerequisites.

### Preparing to Deploy Blueprints
Before you start deploying and testing blueprints, make sure you follow next steps. For example, all blueprints assume that you have an EKS cluster with Karpenter deployed, and others even required that you have a `default` Karpenter `NodePool` deployed.

#### Create an EKS Cluster using Terraform (Optional)

If you're planning on using an existing EKS cluster, you can use an existing node group with On-Demand instances to deploy the Karpenter controller. To do so, you need to follow the [Karpenter getting started guide](https://karpenter.sh/docs/getting-started/).

You'll create an Amazon EKS cluster using the [EKS Blueprints for Terraform project](https://github.com/aws-ia/terraform-aws-eks-blueprints). The Terraform template included in this repository is going to create a VPC, an EKS control plane, and a Kubernetes service account along with the IAM role and associate them using IAM Roles for Service Accounts (IRSA) to let Karpenter launch instances. Additionally, the template configures the Karpenter node role to the `aws-auth` configmap to allow nodes to connect, and creates an On-Demand managed node group for the `kube-system` and `karpenter` namespaces.

To create the cluster, clone this repository and open the `cluster/terraform` folder. Then, run the following commands:

```
cd cluster/terraform
helm registry logout public.ecr.aws
export TF_VAR_region=$AWS_REGION
terraform init
terraform apply -target="module.vpc" -auto-approve
terraform apply -target="module.eks" -auto-approve
terraform apply --auto-approve
```

Before you continue, you need to enable your AWS account to launch Spot instances if you haven't launch any yet. To do so, create the [service-linked role for Spot](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-requests.html#service-linked-roles-spot-instance-requests) by running the following command:

```
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true
```

You might see the following error if the role has already been successfully created. You don't need to worry about this error, you simply had to run the above command to make sure you have the service-linked role to launch Spot instances:

```
An error occurred (InvalidInput) when calling the CreateServiceLinkedRole operation: Service role name AWSServiceRoleForEC2Spot has been taken in this account, please try a different suffix.
```

Once complete (after waiting about 15 minutes), run the following command to update the `kube.config` file to interact with the cluster through `kubectl`:

```
aws eks --region $AWS_REGION update-kubeconfig --name karpenter-blueprints
```

You need to make sure you can interact with the cluster and that the Karpenter pods are running:

```
$> kubectl get pods -n karpenter
NAME                       READY STATUS  RESTARTS AGE
karpenter-5f97c944df-bm85s 1/1   Running 0        15m
karpenter-5f97c944df-xr9jf 1/1   Running 0        15m
```

You can now proceed to deploy the default Karpenter NodePool, and deploy any blueprint you want to test.

#### Deploy a Karpenter Default EC2NodeClass and NodePool

Before you start deploying a blueprint, you need to have a default [EC2NodeClass](https://karpenter.sh/preview/concepts/nodeclasses/) and a default [NodePool](https://karpenter.sh/docs/concepts/nodepools/) as some blueprints need them. `EC2NodeClass` enable configuration of AWS specific settings for EC2 instances launched by Karpenter. The `NodePool` sets constraints on the nodes that can be created by Karpenter and the pods that can run on those nodes. Each NodePool must reference an `EC2NodeClass` using `spec.nodeClassRef`.

If you create a new EKS cluster following the previous steps, a Karpenter `EC2NodeClass` "default" and a Karpenter `NodePool` "default" are installed automatically.

**NOTE:**  For existing EKS cluster you have to modify the provided `./cluster/terraform/karpenter.tf` according to your setup by properly modifying `securityGroupSelectorTerm` and `subnetSelectorTerms` removing the `depends_on` section. 

**NOTE:**  The Karpenter `spec.instanceProfile` field has been removed from the `EC2NodeClass` in favor of the spec.role field. Karpenter now auto-generates the instance profile in your `EC2NodeClass` given the role that you specify.

You can see that the NodePool has been deployed by running this:

```
kubectl get nodepool
```

You can see that the EC2NodeClass has been deployed by running this:

```
kubectl get ec2nodeclass
```

Throughout all the blueprints, you might need to review Karpenter logs, so let's create an alias for that to read logs by simply running `kl`:

```
alias kl="kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true -f --tail=20"
```

You can now proceed to deploy any blueprint you want to test.

#### Terraform Cleanup  (Optional)

Once you're done with testing the blueprints, if you used the Terraform template from this repository, you can proceed to remove all the resources that Terraform created. To do so, run the following commands:

```
kubectl delete namespace karpenter
export TF_VAR_region=$AWS_REGION
terraform destroy -target="module.eks_blueprints_addons" --auto-approve
terraform destroy -target="module.eks" --auto-approve
terraform destroy --auto-approve
```

## Deploying a Blueprint

After you have a cluster up and running with Karpenter installed, you can start testing each blueprint. A blueprint might have a NodePool, EC2NodeClass and a workload example. You need to open the blueprint folder and follow the steps to deploy the resources needed to test the blueprint.

Here's the list of blueprints we have so far:

* [High-Availability: Spread Pods across AZs & Nodes](/blueprints/ha-az-nodes/)
* [Split Between On-Demand & Spot Instances](/blueprints/od-spot-split/)
* [Prioritize Savings Plans and/or Reserved Instances](/blueprints/saving-plans/)
* [Working with Graviton Instances](/blueprints/graviton)
* [Overprovision capacity in advanced to increase responsiveness](/blueprints/overprovision/)
* [Using multiple EBS volumes](/blueprints/multi-ebs/)
* [Working with Stateful Workloads using EBS](/blueprints/stateful/)
* [Update Nodes using Drift](/blueprints/update-nodes-with-drift/)
* [Launching nodes using custom AMIs](/blueprints/custom-ami/)
* [Customizing nodes with your own User Data automation](/blueprints/userdata/)

**NOTE:** Each blueprint is independent from each other, so you can deploy and test multiple blueprints at the same time in the same Kubernetes cluster. However, to reduce noise, we recommend you to test one blueprint at a time.

## Supported Versions

The following table describes the list of resources along with the versions where the blueprints in this repo have been tested.

| Resources/Tool  | Version             |
| --------------- | ------------------- |
| [Kubernetes](https://kubernetes.io/releases/)      | 1.28                |
| [Karpenter](https://github.com/aws/karpenter/releases)       | 0.32.1             |
| [Terraform](https://github.com/hashicorp/terraform/releases)       | 1.6.3             |
| [EKS Blueprints](https://github.com/aws-ia/terraform-aws-eks-blueprints-addons/releases)  | 1.11.0               |

## Feedback

To post feedback, submit a new blueprint, or report bugs, please use the [Issues section](https://github.com/aws-samples/karpenter-blueprints/issues) of this GitHub repo. 

## License

MIT-0 Licensed. See [LICENSE](/LICENSE).
