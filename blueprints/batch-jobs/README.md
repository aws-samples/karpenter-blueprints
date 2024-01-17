# Karpenter Blueprint: Protecting batch jobs during the consolidation process

## Purpose
Karpenter can actively reduce the cluster cost by identifying when nodes can be removed or replaced because they are empty or there are a cheaper one available after some workload change. This process is called [consolidation](https://karpenter.sh/preview/concepts/disruption/#consolidation), and it implies the disruption of pods that are running in the node, if any, as they need to be rescheduled into another node. In some cases, like when running long batch jobs, you don't want those pods to be disrupted. You want to run them from start to finish without disruption, and replace or delete the node once they finish. To achieve that, you can set the `karpenter.sh/do-not-disrupt: "true"` annotation on the pod (more information [here](https://karpenter.sh/preview/concepts/disruption/#pod-level-controls)). By opting pods out of this disruption, you are telling Karpenter that it should not voluntarily remove a node containing this pod.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint you have used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter `NodePool` as that is the one you will use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.

## Deploy
You are going to use the `default` NodePool.

If you want to first observe the default behaviour of pods being disrupted during the consolidation process, jump to [(Optional) Simulating the default behaviour](#(optional)-simulating-the-default-behaviour). 

If you want to directly see how to avoid the disruption of jobs by the consolidation process, jump to [Preventing jobs of being evicted](#preventing-jobs-of-being-evicted).

### (optional) Simulating the default behaviour
This section simulates the default behaviour of the pods explained before, in which the Karpenter consolidation process disrupts the pods running the jobs, and re-schedule them into the cheaper node. To simulate it, deploy the [workloads-evicted yaml](/karpenter-blueprints/blueprints/batch-jobs/workloads-evicted.yaml):
```
$> kubectl apply -f workloads-evicted.yaml
deployment.apps/nginx created
job.batch/2-min-job created
job.batch/5-min-job created
```
This will create three pods that require **11 vCPU** in total:
-  NGINX server - 2 vCPU required
-  2-minutes job - 7 vCPU required
- 5-minutes job - 2 vCPU required

During this test, Karpenter decided to launch a **c6g.4xlarge** on-demand instance (16 vCPU, 32 GiB). You can check this by executing:

```
kubectl get nodes --label-columns node.kubernetes.io/instance-type
``` 
After two minutes, the first job finishes and the pod is terminated:
```
$> kubectl get jobs
NAME        COMPLETIONS   DURATION   AGE
2-min-job   1/1           2m39s      2m40s
5-min-job   0/1           2m40s      2m40s
```
```
> $kubectl get pods
NAME                   READY   STATUS    RESTARTS   AGE
5-min-job-6ffsg        1/1     Running   0          2m50s
nginx-8467c776-r8j24   1/1     Running   0          2m50s
```
Now, the total number of vCPU required by the running pods are **4 vCPU**:
- NGINX server - 2 vCPU required
-  5-minutes job - 2 vCPU required 

The default behaviour is the one defined in the NodePool: `consolidationPolicy: WhenUnderutilized`. Karpenter identifies the **c6g.4xlarge** (12 vCPU) is underutilized, and performs a consolidation replacement of the node. It launches a cheaper and smaller node: a **c6g.2xlarge** (8 vCPU) instance. You can check these logs by executing the following command in another terminal:
```
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true -f --tail=20
```
You should see these logs:
```
{"level":"INFO","time":"2024-01-10T15:06:37.063Z","logger":"controller.disruption","message":"disrupting via consolidation replace, terminating 1 candidates ip-10-0-93-19.eu-west-1.compute.internal/c6g.4xlarge/on-demand and replacing with on-demand node from types r6gd.2xlarge, c7i.2xlarge, r5a.2xlarge, m5a.2xlarge, m6a.2xlarge and 37 other(s)","commit":"1072d3b"}
...
{"level":"INFO","time":"2024-01-10T15:06:39.390Z","logger":"controller.nodeclaim.lifecycle","message":"launched nodeclaim","commit":"1072d3b","nodeclaim":"default-98tsh","nodepool":"default","provider-id":"aws:///eu-west-1a/i-0f329cada644371ec","instance-type":"c6g.2xlarge","zone":"eu-west-1a","capacity-type":"on-demand","allocatable":{"cpu":"7810m","ephemeral-storage":"17Gi","memory":"14003Mi","pods":"58","vpc.amazonaws.com/pod-eni":"38"}}
```
The NGINX server and the 5-min job pods are rescheduled into the new c6g.2xlarge node, so **the job is restarted**, which will cause a disruption the job might not be prepared to handle like doing a checkpoint.

After five more minutes, the job will finish, and Karpenter will replace the node with a **c6g.xlarge** instance (4 vCPU) for the NGINX server. You can repeat the previous steps to verify this behaviour.

To clean up, execute:
```
kubectl delete -f workloads-evicted.yaml
```
To learn how to avoid this behaviour and wait for the job to be finished before replacing the node, go to [Preventing jobs of being evicted](#preventing-jobs-of-being-evicted).

### Preventing jobs of being evicted
If you executed the [optional](#optional-simulating-the-default-behaviour) part, make sure to delete the `workloads-evicted` deployment:
```
kubectl delete -f workloads-evicted.yaml
```

Let's start by deploying the workloads defined in the [workloads-not-evicted yaml](/karpenter-blueprints/blueprints/batch-jobs/workloads-not-evicted.yaml):
```
$> kubectl apply -f workloads-not-evicted.yaml
deployment.apps/nginx created
job.batch/2-min-job created
job.batch/5-min-job created
```
This will create three pods that require **11 vCPU** in total:
-  NGINX server - 2 vCPU required
-  2-minutes job - 7 vCPU required
- 5-minutes job - 2 vCPU required

If you explore the [workloads-not-evicted yaml](/karpenter-blueprints/blueprints/batch-jobs/workloads-not-evicted.yaml), the `karpenter.sh/do-not-disrupt: "true"` annotations have been added to both jobs specifications.

Go to [Results section](#results) to check the behaviour.

***NOTE:***
The sample deployment only allows scheduling pods on on-demand instances (`nodeSelector: karpenter.sh/capacity-type: on-demand`) to show the replace consolidation mechanism, as for spot nodes Karpenter only uses the deletion consolidation mechanism to avoid breaking the price-capacity-optimized strategy, as explained [here](https://karpenter.sh/preview/concepts/disruption/#consolidation).

## Results

### Deployment verification
Karpenter launches the cheapest EC2 instance for the workloads with at least **11 vCPU**: a **c6g.4xlarge** on-demand instance (16 vCPU, 32 GiB). You can check this by executing:
```
kubectl get nodes --label-columns node.kubernetes.io/instance-type
```
You should see something similar to this, where a new node just appeared:

```
NAME                                         STATUS   ROLES    AGE   VERSION               INSTANCE-TYPE
ip-10-0-125-209.eu-west-1.compute.internal   Ready    <none>   16d   v1.28.3-eks-e71965b   m4.large
ip-10-0-46-139.eu-west-1.compute.internal    Ready    <none>   16d   v1.28.3-eks-e71965b   m4.large
ip-10-0-47-60.eu-west-1.compute.internal     Ready    <none>   44s   v1.28.3-eks-e71965b   c6g.4xlarge
```

Check the three new pods are running by executing:
```
$> kubectl get pods
NAME                   READY   STATUS    RESTARTS   AGE
2-min-job-ml6qj        1/1     Running   0          25s
5-min-job-9jc4b        1/1     Running   0          24s
nginx-8467c776-bbl8w   1/1     Running   0          25s
```

You can check the jobs status by executing:
```
$> kubectl get jobs
NAME        COMPLETIONS   DURATION   AGE
2-min-job   0/1           52s        52s
5-min-job   0/1           51s        51s
```

In a different terminal, execute the following command that will display the Karpenter logs in real time:

```
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true -f --tail=20
```
You should see the following events indicating that Karpenter identified the need of a new node, and that it selected an instance type and purchase option:
```
{"level":"INFO","time":"2024-01-08T10:42:35.190Z","logger":"controller.provisioner","message":"found provisionable pod(s)","commit":"1072d3b","pods":"default/2-min-job-ml6qj, default/nginx-8467c776-bbl8w, default/5-min-job-9jc4b","duration":"89.747487ms"}

{"level":"INFO","time":"2024-01-08T10:42:35.190Z","logger":"controller.provisioner","message":"computed new nodeclaim(s) to fit pod(s)","commit":"1072d3b","nodeclaims":1,"pods":3}

{"level":"INFO","time":"2024-01-08T10:42:35.224Z","logger":"controller.provisioner","message":"created nodeclaim","commit":"1072d3b","nodepool":"default","nodeclaim":"default-xzkfq","requests":{"cpu":"11260m","memory":"290Mi","pods":"8"},"instance-types":"c3.4xlarge, c3.8xlarge, c4.4xlarge, c5.4xlarge, c5a.12xlarge and 95 other(s)"}
...
{"level":"INFO","time":"2024-01-08T10:42:37.686Z","logger":"controller.nodeclaim.lifecycle","message":"launched nodeclaim","commit":"1072d3b","nodeclaim":"default-xzkfq","nodepool":"default","provider-id":"aws:///eu-west-1a/i-044f1f028b733d18a","instance-type":"c6g.4xlarge","zone":"eu-west-1a","capacity-type":"on-demand","allocatable":{"cpu":"15790m","ephemeral-storage":"17Gi","memory":"27222Mi","pods":"234","vpc.amazonaws.com/pod-eni":"54"}}

```


### Consolidation Replace blocked due to ongoing job

Around two minutes after the deployment, the first job finishes:
```
$> kubectl get jobs
NAME        COMPLETIONS   DURATION   AGE
2-min-job   1/1           2m41s      2m46s
5-min-job   0/1           2m45s      2m45s
```

The pod executing the job is terminated. Now you should just see two pods, one for the NGINX server and one for the other 5-minutes job:
```
$> kubectl get pods
NAME                   READY   STATUS    RESTARTS   AGE
5-min-job-9jc4b        1/1     Running   0          2m56s
nginx-8467c776-bbl8w   1/1     Running   0          2m57s
```
Now, the total number of vCPU required by the running pods are **4 vCPU**:
- NGINX server - 2 vCPU required
-  5-minutes job - 2 vCPU required

 In contrast to the default behaviour, even though a smaller and cheaper instance could be used, Karpenter reads the `karpenter.sh/do-not-disrupt: "true"` annotation on the 5-minutes job pod and **blocks the consolidation replace** process for that node:

```
$> kubectl describe node <node_name>
...
  Normal    DisruptionBlocked   36s karpenter   Cannot disrupt Node: Pod "default/5-min-job-9jc4b" has do not evict annotation
```

### Consolidation Replace allowed after last job finishes
Around five minutes after the deployment, the other job finishes:
```
$> kubectl get jobs
NAME        COMPLETIONS   DURATION   AGE
5-min-job   1/1           5m40s      5m46s
```
Now, **it is possible to replace the node** by a cheaper and smaller instance because the the NGINX server can be disrupted as it does't contain the `karpenter.sh/do-not-disrupt: "true"` annotation. You can check this in the Karpenter logs terminal:
```
{"level":"INFO","time":"2024-01-08T10:48:46.480Z","logger":"controller.disruption","message":"disrupting via consolidation replace, terminating 1 candidates ip-10-0-47-60.eu-west-1.compute.internal/c6g.4xlarge/on-demand and replacing with on-demand node from types c5n.2xlarge, r6a.2xlarge, m6a.2xlarge, m6id.xlarge, m7gd.xlarge and 103 other(s)","commit":"1072d3b"}
...
{"level":"INFO","time":"2024-01-08T10:48:48.675Z","logger":"controller.nodeclaim.lifecycle","message":"launched nodeclaim","commit":"1072d3b","nodeclaim":"default-7qxqp","nodepool":"default","provider-id":"aws:///eu-west-1b/i-0933fc4784ff30008","instance-type":"c6g.xlarge","zone":"eu-west-1b","capacity-type":"on-demand","allocatable":{"cpu":"3820m","ephemeral-storage":"17Gi","memory":"6425Mi","pods":"58","vpc.amazonaws.com/pod-eni":"18"}}
...
{"level":"INFO","time":"2024-01-08T10:49:30.787Z","logger":"controller.node.termination","message":"tainted node","commit":"1072d3b","node":"ip-10-0-47-60.eu-west-1.compute.internal"}

{"level":"INFO","time":"2024-01-08T10:49:39.385Z","logger":"controller.node.termination","message":"deleted node","commit":"1072d3b","node":"ip-10-0-47-60.eu-west-1.compute.internal"}
```
Karpenter replaces the **c6g.4xlarge** (16 vCPU, 32 GiB) with a **c6g.xlarge** node (4 vCPU, 8 GiB), enough for the NGINX server: 
```
$> kubectl get nodes --label-columns node.kubernetes.io/instance-type
NAME                                         STATUS   ROLES    AGE   VERSION               INSTANCE-TYPE
ip-10-0-125-209.eu-west-1.compute.internal   Ready    <none>   17d   v1.28.3-eks-e71965b   m4.large
ip-10-0-46-139.eu-west-1.compute.internal    Ready    <none>   17d   v1.28.3-eks-e71965b   m4.large
ip-10-0-85-30.eu-west-1.compute.internal     Ready    <none>   26s   v1.28.3-eks-e71965b   c6g.xlarge
```
Finally, you can check the NGINX server pod has been re-scheduled into the new pod:
```
$> kubectl get pods
NAME                   READY   STATUS    RESTARTS   AGE
nginx-8467c776-vjwgv   1/1     Running   0          22s
```

## Cleanup

```
kubectl delete -f .
```