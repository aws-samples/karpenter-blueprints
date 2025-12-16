# Karpenter Blueprint: Deploy an NVIDIA GPU workload

## Purpose

Karpenter streamlines node lifecycle management, and it can help provide the right compute just-in-time based on your workloads scheduling constraints. This is particularly helpful for your machine learning workflows with variable and heterogeneous compute demands (e.g., NVIDIA GPU-based inference followed by CPU-based plotting). When your Kubernetes workload requires accelerated instance, Karpenter automatically selects the appropriate [Amazon EKS optimized accelerated AMI](https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-ami.html).

Therefore, the purpose of this Karpenter blueprint is to demonstrate how to launch a GPU-based workload on Amazon EKS with Karpenter and AL2023 EKS optimized accelerated AMI. This example assumes a simple one-to-one mapping between a Kubernetes Pod and a GPU. This blueprint does not go into the details about GPU sharing techniques such as MiG, time slicing or other software based GPU fractional scheduling.

Before you start seeing Karpenter in action, when using AL2023 you need to deploy a Kubernetes device plugin to advertise GPU information from the host.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.

## Deploy NVIDIA device plugin for Kubernetes

The [NVIDIA device plugin for Kubernetes](https://github.com/NVIDIA/k8s-device-plugin) is used to advertise the number of GPUs on the host to Kubernetes so that this information can be used for scheduling purposes. You can install the NVIDIA device plugin with helm.

To install the device plugin run the following:

```sh
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
# Check available versions: helm show chart nvdp/nvidia-device-plugin
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --version 0.18.0
```

**Confirm installation:**
```sh
helm list -n nvidia-device-plugin
```

Now that you have the device set-up, let’s enable Karpenter to launch NVIDIA GPU instances.

## Create a NodeClass and NodePool with GPU-instances (AL2023)

The following NodeClass, specify the Security Group and Subnet selector, along with AMI. We are using AL2023 here, and when launching an accelerated instance Karpenter will pick the respective EKS optimized accelerated AMI. AL2023 comes packaged with the NVIDIA GPU drivers, and the container runtime is configured out of the box.

Before applying the `gpu-nodeclass.yaml` replace `KARPENTER_NODE_IAM_ROLE_NAME` and `CLUSTER_NAME` in the file with your specific cluster details. If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role(not the ARN).

The EC2NodeClass we’ll deploy looks like this, execute the following command to create the EC2NodeClass file:

```sh
cat << EOF > gpu-nodeclass.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu
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
```

A separate [EC2NodeClass](https://karpenter.sh/docs/concepts/nodeclasses/) was created as you may want to tune node properties such as ephemeral storage size, block device mappings, [capacity reservations selector](https://karpenter.sh/docs/concepts/nodeclasses/).

The next step is to create a dedicated NodePool to provision instances from the `g` Amazon EC2 instance category and nvidia gpu manufacturer, and only allow workloads that tolerate the `nvidia.com/gpu` taint to be scheduled. Such NodePool will look like this. Execute the following command to create the NodePool file:

```sh
cat << EOF > gpu-nodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu
spec:
  limits:
    cpu: 100
    memory: 100Gi
    nvidia.com/gpu: 5
  template:
    metadata:
      labels:
        nvidia.com/gpu.present: "true"
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        name: gpu
        kind: EC2NodeClass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["g"]
        - key: karpenter.k8s.aws/instance-gpu-manufacturer
          operator: In
          values: ["nvidia"]
      expireAfter: 720h
      taints:
         - key: nvidia.com/gpu
           effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m
EOF
```

We’ve added the `nivida.com/gpu` taint in the NodePool to prevent workloads that do not tolerate this taint being scheduled on nodes managed by this NodePool (they might not take advantage of it). Also, notice that the `.spec.disruption` policy has been set to WhenEmpty and only consolidate after 5 minutes, this is to support spiky workloads like jobs with a high-churn - you’ll likely want to tweak this based on your workloads requirements.

Once the placeholders are complete, to apply the EC2NodeClass and NodePool execute the following:

```sh
$> kubectl apply -f gpu-nodeclass.yaml
ec2nodeclass.karpenter.k8s.aws/gpu created

$> kubectl apply -f gpu-nodepool.yaml
nodepool.karpenter.sh/gpu created
```

Now let’s deploy a test workload to see how Karpenter launches the GPU node.

### Deploy a test workload to test GPU drivers are loaded

The following Pod manifest launches a pod and calls the NVIDIA systems management CLI to check if a GPU is detected and the driver versions printed to standard output, which you can see when you check the logs, like this: `kubectl logs pod/nvidia-smi`. Execute the following command to create the `workload.yaml`:

```sh
cat << EOF > workload.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi
spec:
  nodeSelector:
    nvidia.com/gpu.present: "true"
    karpenter.k8s.aws/instance-gpu-name: "t4"
  restartPolicy: OnFailure
  containers:
  - name: nvidia-smi
    image: public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
    args:
    - "nvidia-smi"
    resources:
      requests:
        memory: "8Gi"
        cpu: "3500m"
      limits:
        memory: "8Gi"
        nvidia.com/gpu: 1
  tolerations:
  - key: nvidia.com/gpu
    effect: NoSchedule
    operator: Exists
EOF
```

As GPU-based workloads are likely sensitive to different GPUs (e.g. GPU memory) we've specified a `karpenter.k8s.aws/instance-gpu-name` node selector to request an instance with a specific GPU for this workload. The following nodeSelector `karpenter.k8s.aws/instance-gpu-name: "t4"` influences Karpenter node provisioning and launch the workload on a node with a [NVIDIA T4 GPU](https://aws.amazon.com/ec2/instance-types/g4/). Review the [Karpenter documentation](https://karpenter.sh/docs/reference/instance-types/) for different Amazon EC2 instances and there labels.

To deploy the workload execute the following:

```sh
$> kubectl apply -f workload.yaml
pod/nvidia-smi created
```

You can check the pods status by executing:

```sh
$> kubectl get pods
NAME         READY   STATUS    RESTARTS   AGE
nvidia-smi   1/1     Running   0          3s
```

You can view the pods nvidia-smi logs by executing:

```sh
$> kubectl logs pod/nvidia-smi

+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 580.105.08             Driver Version: 580.105.08     CUDA Version: 13.0     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  Tesla T4                       On  |   00000000:00:1E.0 Off |                    0 |
| N/A   30C    P8              9W /   70W |       0MiB /  15360MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|  No running processes found                                                             |
+-----------------------------------------------------------------------------------------+
```

To review which node was launched by Karpenter, execute the following:

```sh
$> kubectl get nodeclaims

NAME        TYPE           CAPACITY    ZONE         NODE                                          READY   AGE
gpu-f69tm   g4dn.2xlarge   on-demand   eu-west-1c   ip-xxx-xxx-xxx-xxx.eu-west-1.compute.internal True    5m44s
```

## Clean-up

To clean-up execute the following commands:

```sh
kubectl delete -f workload.yaml
kubectl delete -f gpu-nodepool.yaml
kubectl delete -f gpu-nodeclass.yaml
helm -n nvidia-device-plugin uninstall nvdp
```
