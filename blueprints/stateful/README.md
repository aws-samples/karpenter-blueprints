# Karpenter Blueprint: Working with Stateful Workloads using EBS

## Purpose
For stateful workloads that use persistent volumes, Karpenter detects storage scheduling requirements when deciding which instance type to launch and in which AZ. If you have a `StorageClass` configured for multiple AZs, Karpenter randomly selects one AZ when the pod is created for the first time. If the same pod is then removed, a new pod is created to request the same Persistent Volume Claim (PVC) and Karpenter takes this into consideration when choosing the AZ of an existing claim.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter `NodePool` as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.
* The [Amazon EBS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/managing-ebs-csi.html) installed in the cluster. If you're using the Terraform template in this repository, it's already configured.

## Deploy
Let's start by creating the `PersistentVolumeClaim` and `StorageClass` to use only one AZ. To do so,first choose one of the AZs in the region where you deployed the EKS cluster. Run this command to get one automatically:

```
export FIRSTAZ=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)
echo $FIRSTAZ
```

Then, run these commands to replace the placeholder with the AZ, and deploy the storage resources:

```
sed -i '' "s/<<AVAILABILITY_ZONE>>/$FIRSTAZ/g" storage.yaml
kubectl apply -f storage.yaml
```

Wait around one minute, as long as you get an event of `WaitForFirstConsumer` in the PVC, you're good to continue:

```
> kubectl describe pvc ebs-claim
...
Events:
  Type    Reason                Age                   From                         Message
  ----    ------                ----                  ----                         -------
  Normal  WaitForFirstConsumer  14s (x16 over 3m47s)  persistentvolume-controller  waiting for first consumer to be created before binding
```

Deploy a sample workload:

```
kubectl apply -f workload.yaml
```

## Results
After waiting for around two minutes, you should see the stateful set running, and the PVC claimed:

```
> kubectl get pods
NAME         READY   STATUS    RESTARTS   AGE
stateful-0   1/1     Running   0          95s
stateful-1   1/1     Running   0          84s
stateful-2   1/1     Running   0          27s

> kubectl get pvc
NAME        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistent-storage-stateful-0   Bound     pvc-888c8df5-53b1-45db-9031-04ff1123374d   4Gi        RWO            storage-gp3    <unset>                 6m35s
persistent-storage-stateful-1   Bound     pvc-5913f231-11ae-42fe-bc41-a0185fc16eb9   4Gi        RWO            storage-gp3    <unset>                 6m24s
persistent-storage-stateful-2   Bound     pvc-cd9a4029-3951-43ea-a210-afc9a3ab08c9   4Gi        RWO            storage-gp3    <unset>                 5m27s
```

Notice that Karpenter launched a node in the AZ (using the value from `$FIRSTAZ` env var), following the constraint defined in the `StorageClass` (no need to constraint it within the `StatefulSet` or `Pod`):

```
> kubectl get nodes -L karpenter.sh/capacity-type,beta.kubernetes.io/instance-type,karpenter.sh/nodepool,topology.kubernetes.io/zone -l karpenter.sh/initialized=true
NAME                                       STATUS   ROLES    AGE     VERSION               CAPACITY-TYPE   INSTANCE-TYPE   NODEPOOL   ZONE
ip-xxx-xxx-xxx-xxx.eu-west-2.compute.internal    Ready    <none>   16s   v1.33.0-eks-802817d   spot            m7g.xlarge      default    eu-west-2a
```

Let's read the file that the pods are writing to, like this:

```
export POD=$(kubectl get pods -l app=stateful -o name | cut -d/ -f2 | tail -n1)
kubectl exec $POD -- cat /data/out.txt
```

You should see that the three pods are writing something every three minutes, like this:

```
Writing content every three minutes! Printing a random number: 795
Writing content every three minutes! Printing a random number: 600
Writing content every three minutes! Printing a random number: 987
```

If you delete one pod, the new pod will continue using the same PVC and will be in a `Running` state:

```
kubectl delete pod $POD
```

You can read the content of the file using the new pod:

```
export POD=$(kubectl get pods -l app=stateful -o name | cut -d/ -f2 | tail -n1)
kubectl exec $POD -- cat /data/out.txt
```

You should still see the previous content plus any additional content if three minutes have passed, like this:

```
Writing content every three minutes! Printing a random number: 795
Writing content every three minutes! Printing a random number: 600
Writing content every three minutes! Printing a random number: 987
Writing content every three minutes! Printing a random number: 224
Writing content every three minutes! Printing a random number: 307
Writing content every three minutes! Printing a random number: 325
```

Lastly, you can simulate a scale-down event for the workload and scale the replicas to 0, like this:

```
kubectl scale statefulset stateful --replicas=0
```

Wait around two minutes, and consolidation will make sure to remove the node. You can then scale-out the workload again, like this:

```
kubectl scale statefulset stateful --replicas=3
```

And you should see that Karpenter launches a replacement node in the AZ you choose, and the pods are soon going to be in a `Running` state.

**NOTE:** You might have a experience/simulate a node loss which can result in data corruption or loss. If this happens, when the new node launched by Karpenter is ready, pods might have a warning event like `Multi-Attach error for volume "pvc-19af27b8-fc0a-428d-bda5-552cb52b9806" Volume is already exclusively attached to one node and can't be attached to another`. You can wait around five minutes and the volume will try to get unattached, and attached again, making your pods successfully run again. Look at this series of events for reference:

```
> kubectl get events -w

Events:
  Type     Reason                  Age                  From                     Message
  ----     ------                  ----                 ----                     -------
  Warning  FailedScheduling        14m                  default-scheduler        0/3 nodes are available: 1 node(s) were unschedulable, 2 node(s) didn't match Pod's node affinity/selector. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling..
  Normal   Nominated               14m                  karpenter                Pod should schedule on: machine/default-75hvl
  Warning  FailedScheduling        14m (x2 over 14m)    default-scheduler        0/3 nodes are available: 1 node(s) had volume node affinity conflict, 2 node(s) didn't match Pod's node affinity/selector. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling..
  Normal   Scheduled               14m                  default-scheduler        Successfully assigned default/stateful-7b68c8d7bc-6mkvn to ip-xxx-xxx-xxx-xxx.eu-west-1.compute.internal
  Warning  FailedAttachVolume      14m                  attachdetach-controller  Multi-Attach error for volume "pvc-19af27b8-fc0a-428d-bda5-552cb52b9806" Volume is already exclusively attached to one node and can't be attached to another
  Warning  FailedMount             9m52s (x2 over 12m)  kubelet                  Unable to attach or mount volumes: unmounted volumes=[persistent-storage], unattached volumes=[persistent-storage], failed to process volumes=[]: timed out waiting for the condition
  Normal   SuccessfulAttachVolume  8m53s                attachdetach-controller  AttachVolume.Attach succeeded for volume "pvc-19af27b8-fc0a-428d-bda5-552cb52b9806"
  Normal   Pulling                 8m51s                kubelet                  Pulling image "centos"
  Normal   Pulled                  8m47s                kubelet                  Successfully pulled image "centos" in 4.871822072s (4.871840882s including waiting)
  Normal   Created                 8m47s                kubelet                  Created container stateful
  Normal   Started                 8m46s                kubelet                  Started container stateful
```

Finally, you can read the content of the file again:

```
export POD=$(kubectl get pods -l app=stateful -o name | cut -d/ -f2 | tail -n1)
kubectl exec $POD -- cat /data/out.txt
```

## Cleanup
To remove all objects created, simply run the following commands:

```
kubectl delete -f .
```
