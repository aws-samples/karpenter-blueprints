# Karpenter Blueprint: Working with Graviton Instances

## Purpose
You might be wondering how to use Graviton instances with Karpenter. Well, first you need to make sure that your application can run on different CPUs such as `arm64` or `x86-64`. The programming language you’re using and its ecosystem needs to be multi-arch aware, as you'll need to container images for both `arm64` and `x86-64` architectures. [AWS Graviton](https://aws.amazon.com/ec2/graviton/) processors are custom built by AWS using 64-bit Arm Neoverse. They power Amazon EC2 instances such as: M6g, M6gd, T4g, C6g, C6gd, C6gn, R6g, R6gd, X2gd, and more. Graviton instances provide up to 40% better price performance over comparable current generation x86-based instances for a wide variety of workloads.

Karpenter set the default architecture constraint on your NodePool that supports most common user workloads, which today will be `amd64` (or `x86-64` architecture). However, if you're flexible to support either `arm64` or `x86-64`, when working with AWS, you defer the decision of which architecture to use depending on purchase model: `On-Demand` or `Spot`.

If it’s an On-Demand Instance, Karpenter uses the `lowest-price` (LP) allocation strategy to launch the cheapest instance type that has available capacity. If it’s a Spot Instance, Karpenter uses the `price-capacity-optimized` (PCO) allocation strategy. PCO looks at both price and capacity availability to launch from the [Spot Instance pools](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html#spot-features) that are the least likely to be interrupted and have the lowest possible price.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter `NodePool` as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.
* A container image built for `arm64` architecture hosted in a container image registry such as ECR.

**NOTE:** To build a multi-arch container image, you can use Docker‘s [buildx](https://www.docker.com/blog/multi-arch-build-and-images-the-simple-way/) or, equally possible, a [remote](https://community.arm.com/developer/tools-software/tools/b/tools-software-ides-blog/posts/unifying-arm-software-development-with-docker) build. In this context, you want to check the [multi-arch readiness](https://github.com/aws-samples/aws-multiarch-container-build-pipeline) of your automated build and test pipeline, for example, [[support in Travis](https://docs.travis-ci.com/user/multi-cpu-architectures/#example-multi-architecture-build-matrix). Next, you need to [push your container images to a registry such as ECR](https://aws.amazon.com/blogs/containers/introducing-multi-architecture-container-images-for-amazon-ecr/).

**NOTE:** The sample `workload` in this repository already supports `arm64`.

## Deploy
You're going to use the `default` NodePool as there's no need to create a separate NodePool to launch Graviton instances.

## Results
You can inspect the pods from the `workload-flexible` deployment, but they don't have something in particular for Graviton instances other than asking for On-Demand capacity (`karpenter.sh/capacity-type: on-demand`) as a node selector. So, let's deploy the following assets:

```
kubectl apply -f workload-flexible.yaml
```

Wait for about one minute, and you'll see a new Graviton instance coming up:

```
$> kubectl get nodeclaims
NAME            TYPE         ZONE         NODE                                            READY   AGE
default-sgmkw   c6g.xlarge   eu-west-1b   ip-xxx-xxx-xxx-xxx.eu-west-1.compute.internal   True    42s
```

**NOTE:** All pods should be running now, and you didn't have to say anything special to Karpenter about which container image to use. Why? In Kubernetes, and by extension in Amazon EKS, the worker node-local supervisor called `kubelet` instructs the container runtime via a [standardized interface](https://kubernetes.io/blog/2016/12/container-runtime-interface-cri-in-kubernetes/) to pull container images from a registry such as Amazon ECR and launch them, accordingly. All of which is multi-arch enabled and automated.

Now, let's suppose that you've make the decision to go all-in with Graviton. Instead of creating a new NodePool, you can control that behavior within the `Deployment` by using a `nodeSelector` of `kubernetes.io/arch: arm64` and without limiting to On-Demand only. This means that now chances are that Karpenter will launch a Spot instance as it's the one with a better price offering. Let's see, deploy the other workload:

```
kubectl apply -f workload-graviton.yaml
```

Wait for about one minute, and run the following command to see which nodes Karpenter has launched and see if it's On-Demand or Spot:

```
kubectl get nodes -L karpenter.sh/capacity-type,beta.kubernetes.io/instance-type,karpenter.sh/nodepool,topology.kubernetes.io/zone -l karpenter.sh/initialized=true
```

You should see something similar to this:

```
NAME                                              STATUS   ROLES    AGE    VERSION               CAPACITY-TYPE
ip-xxx-xxx-xxx-xxx.eu-west-2.compute.internal     Ready    <none>   3m23s   v1.33.0-eks-802817d   on-demand       c6g.xlarge      default    eu-west-2a
ip-xxx-xxx-xxx-xxx.eu-west-2.compute.internal   Ready    <none>   77s     v1.33.0-eks-802817d     spot            c7gd.xlarge     default    eu-west-2c
```

Notice that now Karpenter decided to launch a `c7g.xlarge` Spot instance because the workload and the NodePool support both pricing models, and the one that has a better price at this moment was a Graviton Spot instance.

## Cleanup

```
kubectl delete -f .
```
