# Karpenter Blueprint: Protecting batch jobs during the disruption (consolidation) process

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

The default behaviour is the one defined in the NodePool: `consolidationPolicy: WhenEmptyOrUnderutilized`. Karpenter identifies the **c6g.4xlarge** (12 vCPU) is underutilized, and performs a consolidation replacement of the node. It launches a cheaper and smaller node: a **c6g.2xlarge** (8 vCPU) instance. You can check these logs by executing the following command in another terminal:
```
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true -f --tail=20
```
You should see these logs:
```
{"level":"INFO","time":"2024-08-16T10:03:46.529Z","logger":"controller","message":"disrupting nodeclaim(s) via replace, terminating 1 nodes (2 pods) ip-10-0-122-231.eu-west-2.compute.internal/c6g.4xlarge/on-demand and replacing with on-demand node from types c6g.2xlarge, c7g.2xlarge, m6g.2xlarge, c6a.2xlarge, c5a.2xlarge and 32 other(s)","commit":"5bdf9c3","controller":"disruption","namespace":"","name":"","reconcileID":"857f7bb5-a482-48e8-9c52-16a10823e2e4","command-id":"25beb85a-3020-4267-a525-5273e0afc7a7","reason":"underutilized"}
...
{"level":"INFO","time":"2024-08-16T10:03:48.591Z","logger":"controller","message":"launched nodeclaim","commit":"5bdf9c3","controller":"nodeclaim.lifecycle","controllerGroup":"karpenter.sh","controllerKind":"NodeClaim","NodeClaim":{"name":"default-r9nzz"},"namespace":"","name":"default-r9nzz","reconcileID":"def551ff-c16e-4b1c-a137-f79df8724ded","provider-id":"aws:///eu-west-2a/i-0cefe0bfe63f80b39","instance-type":"c6g.2xlarge","zone":"eu-west-2a","capacity-type":"on-demand","allocatable":{"cpu":"7910m","ephemeral-storage":"17Gi","memory":"14103Mi","pods":"58","vpc.amazonaws.com/pod-eni":"38"}}
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
ip-10-0-125-209.eu-west-1.compute.internal   Ready    <none>   16d   v1.30.2-eks-1552ad0   m4.large
ip-10-0-46-139.eu-west-1.compute.internal    Ready    <none>   16d   v1.30.2-eks-1552ad0   m4.large
ip-10-0-47-60.eu-west-1.compute.internal     Ready    <none>   44s   v1.30.2-eks-1552ad0   c6g.4xlarge
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
{"level":"INFO","time":"2024-08-16T10:10:47.683Z","logger":"controller","message":"found provisionable pod(s)","commit":"5bdf9c3","controller":"provisioner","namespace":"","name":"","reconcileID":"d8e8907d-5b93-46bb-893a-63520f3ec12f","Pods":"default/2-min-job-czp5x","duration":"39.859328ms"}

{"level":"INFO","time":"2024-08-16T10:10:47.683Z","logger":"controller","message":"computed new nodeclaim(s) to fit pod(s)","commit":"5bdf9c3","controller":"provisioner","namespace":"","name":"","reconcileID":"d8e8907d-5b93-46bb-893a-63520f3ec12f","nodeclaims":1,"pods":1}

{"level":"INFO","time":"2024-08-16T10:10:47.699Z","logger":"controller","message":"created nodeclaim","commit":"5bdf9c3","controller":"provisioner","namespace":"","name":"","reconcileID":"d8e8907d-5b93-46bb-893a-63520f3ec12f","NodePool":{"name":"default"},"NodeClaim":{"name":"default-g4kgp"},"requests":{"cpu":"7260m","memory":"290Mi","pods":"6"},"instance-types":"c4.2xlarge, c5.2xlarge, c5.4xlarge, c5a.2xlarge, c5a.4xlarge and 55 other(s)"}
...
{"level":"INFO","time":"2024-08-16T10:10:49.959Z","logger":"controller","message":"launched nodeclaim","commit":"5bdf9c3","controller":"nodeclaim.lifecycle","controllerGroup":"karpenter.sh","controllerKind":"NodeClaim","NodeClaim":{"name":"default-g4kgp"},"namespace":"","name":"default-g4kgp","reconcileID":"ff5b7f6e-c52e-495e-94b1-3a30385c3439","provider-id":"aws:///eu-west-2a/i-022a05d79bceda579","instance-type":"c6g.2xlarge","zone":"eu-west-2a","capacity-type":"on-demand","allocatable":{"cpu":"7910m","ephemeral-storage":"17Gi","memory":"14103Mi","pods":"58","vpc.amazonaws.com/pod-eni":"38"}}

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
  Normal    DisruptionBlocked   36s karpenter   Cannot disrupt Node: pod "default/2-min-job-czp5x" has "karpenter.sh/do-not-disrupt" annotation
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
{"level":"INFO","time":"2024-08-16T10:17:21.322Z","logger":"controller","message":"created nodeclaim","commit":"5bdf9c3","controller":"disruption","namespace":"","name":"","reconcileID":"1135db0e-45ef-4529-9492-63789a9837c6","NodePool":{"name":"default"},"NodeClaim":{"name":"default-9m4bv"},"requests":{"cpu":"2260m","memory":"290Mi","pods":"6"},"instance-types":"c4.xlarge, c5.xlarge, c5a.xlarge, c5d.xlarge, c5n.xlarge and 32 other(s)"}
...
{"level":"INFO","time":"2024-08-16T10:17:23.452Z","logger":"controller","message":"launched nodeclaim","commit":"5bdf9c3","controller":"nodeclaim.lifecycle","controllerGroup":"karpenter.sh","controllerKind":"NodeClaim","NodeClaim":{"name":"default-9m4bv"},"namespace":"","name":"default-9m4bv","reconcileID":"f0e0cc47-45a9-479c-a1c7-b5f0f0341026","provider-id":"aws:///eu-west-2a/i-0a4fa068af5550afa","instance-type":"c6g.xlarge","zone":"eu-west-2a","capacity-type":"on-demand","allocatable":{"cpu":"3920m","ephemeral-storage":"17Gi","memory":"6525Mi","pods":"58","vpc.amazonaws.com/pod-eni":"18"}}
...
{"level":"INFO","time":"2024-08-16T10:18:07.430Z","logger":"controller","message":"tainted node","commit":"5bdf9c3","controller":"node.termination","controllerGroup":"","controllerKind":"Node","Node":{"name":"ip-10-0-42-175.eu-west-2.compute.internal"},"namespace":"","name":"ip-10-0-42-175.eu-west-2.compute.internal","reconcileID":"a57044a6-f00f-41e5-a1ab-31e4b19dd838","taint.Key":"karpenter.sh/disrupted","taint.Value":"","taint.Effect":"NoSchedule"}

{"level":"INFO","time":"2024-08-16T10:18:50.331Z","logger":"controller","message":"deleted node","commit":"5bdf9c3","controller":"node.termination","controllerGroup":"","controllerKind":"Node","Node":{"name":"ip-10-0-42-175.eu-west-2.compute.internal"},"namespace":"","name":"ip-10-0-42-175.eu-west-2.compute.internal","reconcileID":"2a51acf8-702f-4c75-988d-92052d690b01"}
```
Karpenter replaces the **c6g.4xlarge** (16 vCPU, 32 GiB) with a **c6g.xlarge** node (4 vCPU, 8 GiB), enough for the NGINX server: 
```
$> kubectl get nodes --label-columns node.kubernetes.io/instance-type
NAME                                         STATUS   ROLES    AGE   VERSION               INSTANCE-TYPE
ip-10-0-125-209.eu-west-1.compute.internal   Ready    <none>   17d   v1.30.2-eks-1552ad0   m4.large
ip-10-0-46-139.eu-west-1.compute.internal    Ready    <none>   17d   v1.30.2-eks-1552ad0   m4.large
ip-10-0-85-30.eu-west-1.compute.internal     Ready    <none>   26s   v1.30.2-eks-1552ad0   c6g.xlarge
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