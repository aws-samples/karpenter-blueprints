# Karpenter Blueprint: Deploy an AWS Trainium or AWS Inferentia workload

Karpenter streamlines managing accelerated instance node lifecycle management. When you specify accelerated instance types in your Karpenter NodePool, Karpenter automatically selects the appropriate Amazon EKS AMI. Karpenter's provisioning also enables efficient use of Spot Instances across a diverse range of instance types - you can specify multiple accelerator options in your NodePool configuration. This flexibility allows you to balance performance and cost-effectiveness while running accelerator workloads in your Amazon EKS cluster.

When using AL2023 and Bottlerocket you need to deploy a Neuron Kubernetes device plugin to advertise neuron devices from the host. To use neuron accelerators you need the neuron driver. For AL2023 there is a [Neuron EKS Accelerated AMI](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html#eks-amis-neuron-al2023) which is packaged with the Neuron driver, whereas with Bottlerocket [standard EKS Bottlerocket AMI](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html#eks-amis-neuron-bottlerocket) includes the Neuron driver.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.

## Deploy Neuron Helm Chart for Kubernetes

The neuron helm chart simplifies installation of the Kubernetes device plugin for Neuron, Neuron Scheduler and Neuron Node Problem Detector. The Neuron Scheduler Extension is disabled by default. The Neuron scheduler extension is required for scheduling pods that require more than one Neuron core or device resource. For a graphical depiction of how the Neuron scheduler extension works, see [Neuron Scheduler Extension Flow Diagram](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/containers/tutorials/k8s-neuron-scheduler-flow.html#k8s-neuron-scheduler-flow). The Neuron scheduler extension finds sets of directly connected devices with minimal communication latency when scheduling containers. 

If you require the neuron scheduler, this can be deployed on a general purpose or system NodePool with general purpose compute. You can override the scheduler name as part of the helm chart install `scheduler.customScheduler.fullnameOverride` property. To use the neuron scheduler you must specify the `schedulerName` in your Pod specification.

For configuring the Neuron Node Problem Detector see the following AWS Neuron [documentation](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/containers/kubernetes-getting-started.html#neuron-node-problem-detector-plugin).

To install the neuron helm chart run the following:

```sh
helm install neuron-helm-chart \
  oci://public.ecr.aws/neuron/neuron-helm-chart \
  --set "scheduler.enabled=true" \
  --set "scheduler.customScheduler.fullnameOverride=neuron-scheduler" \
  --set "npd.enabled=false" \
  --namespace kube-system
```

By default, the neuron device plugin and scheduler are deployed in `kube-system`.

The neuron device plugin advertises both neuron cores `aws.amazon.com/neuroncore` and neuron devices `aws.amazon.com/neuron` to the kubelet. When scheduling a workload on `aws.amazon.com/neuron` all cores associated with that neuron device will be allocated to the Pod.

**Confirm installation:**
```sh
helm ls
```

Now that you have the device set-up, let’s enable Karpenter to launch AWS Trainium / Inferentia Amazon EC2 Instances.

## Create a NodeClass and NodePool with AWS Trainium / Inferentia Amazon EC2 Instances (AL2023)

The following NodeClass, specify the Security Group and Subnet selector, along with AMI. We are using AL2023 here, and when launching an accelerated instance Karpenter will pick the respective EKS optimized AMI.

Before applying the `neuron-nodeclass.yaml` replace `KARPENTER_NODE_IAM_ROLE_NAME` and `CLUSTER_NAME` in the file with your specific cluster details. If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role(not the ARN).

The EC2NodeClass we’ll deploy looks like this, execute the following command to create the EC2NodeClass file:

```sh
cat << EOF > neuron-nodeclass.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: neuron
spec:
  amiSelectorTerms:
  - alias: al2023@latest
  role: "$KARPENTER_NODE_IAM_ROLE_NAME"
  blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      deleteOnTermination: true
      iops: 10000
      throughput: 125
      volumeSize: 100Gi
      volumeType: gp3
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: $CLUSTER_NAME
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: $CLUSTER_NAME
EOF

kubectl apply -f neuron-nodeclass.yaml
```

A separate [EC2NodeClass](https://karpenter.sh/docs/concepts/nodeclasses/) was created as you may want to tune node properties such as ephemeral storage size, block device mappings, [capacity reservations selector](https://karpenter.sh/docs/concepts/nodeclasses/).

Create a dedicated NodePool, states provision instances from `inf` and `trn` category, and only allow workloads that tolerate the `aws.amazon.com/neuron taint` to be scheduled. Apply the following NodePool.

```sh
cat << EOF > neuron-nodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: neuron
spec:
  limits:
    cpu: 100
    memory: 100Gi
    aws.amazon.com/neuron: 5
  template:
    metadata:
      labels:
        intent: neuron
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        name: neuron 
        kind: EC2NodeClass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["inf", "trn"]
      expireAfter: 720h
      taints:
         - key: aws.amazon.com/neuron
           effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m
EOF

kubectl apply -f neuron-nodepool.yaml
```

We’ve added the `aws.amazon.com/neuron` taint in the NodePool to prevent workloads that do not tolerate this taint being scheduled on nodes managed by this NodePool (they might not take advantage of it).

Now let’s deploy a test workload.

## Deploy a test workload to test neuron drivers are loaded

The following Pod manifest launches a pod and calls the Neuron CLI to check if the accelerator is detected and the driver versions printed to standard output, use `kubectl logs pod/neuron-ls` to observe. Create `workload.yaml` from the following Pod specification: 

```sh
cat << EOF > workload.yaml
apiVersion: v1
kind: Pod
metadata:
  name: neuron-ls
spec:
  nodeSelector:
    intent: neuron
    karpenter.k8s.aws/instance-accelerator-name: inferentia
  restartPolicy: OnFailure
  schedulerName: neuron-scheduler
  containers:
  - name: neuron-ls
    image: public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.13.0-neuronx-py312-sdk2.27.1-ubuntu24.04
    args:
    - "neuron-ls"
    resources:
      requests:
        memory: "30Gi"
        cpu: "3500m"
      limits:
        memory: "30Gi"
        aws.amazon.com/neuron: 2
  tolerations:
  - key: aws.amazon.com/neuron
    effect: NoSchedule
    operator: Exists
EOF
```

Notice, we set a node selector `karpenter.k8s.aws/instance-accelerator-name` to specify the accelerator. We also set the `schedulerName` to `neuron-scheduler`.

To deploy the workload execute the following:

```sh
$> kubectl apply -f workload.yaml
pod/neuron-ls created
```

After sometime to list nodes, neuron devices and cores run the following:

```sh
$> kubectl get nodes "-o=custom-columns=NAME:.metadata.name,NeuronDevices:.status.allocatable.aws\.amazon\.com/neuron,NeuronCores:.status.allocatable.aws\.amazon\.com/neuroncore"

NAME                        NeuronDevices   NeuronCores
ip-xx-x-x-xxx.ec2.internal  4               16
```

You can check the pods status by executing:

```sh
$> kubectl get pods
NAME        READY   STATUS    RESTARTS   AGE
neuron-ls   1/1     Running   0          4m36s
```

You can view the pods neuron-smi logs by executing:

```sh
$> kubectl logs pod/neuron-ls

instance-type: inf1.6xlarge
instance-id: <redacted>
+--------+--------+----------+--------+-----------+--------------+----------+------+
| NEURON | NEURON |  NEURON  | NEURON | CONNECTED |     PCI      |   CPU    | NUMA |
| DEVICE | CORES  | CORE IDS | MEMORY |  DEVICES  |     BDF      | AFFINITY | NODE |
+--------+--------+----------+--------+-----------+--------------+----------+------+
| 0      | 4      | 0-3      | 8 GB   | 1         | 0000:00:1c.0 | 0-23     | -1   |
| 1      | 4      | 4-7      | 8 GB   | 2, 0      | 0000:00:1d.0 | 0-23     | -1   |
+--------+--------+----------+--------+-----------+--------------+----------+------+
```

## Clean-up

To clean-up execute the following commands:

```sh
kubectl delete -f workload.yaml
kubectl delete -f neuron-nodepool.yaml
kubectl delete -f neuron-nodeclass.yaml
helm delete -n kube-system neuron-helm-chart
```
