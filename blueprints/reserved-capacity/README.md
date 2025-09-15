# Karpenter Blueprint: Prioritize Reserved Capacity

## Purpose

If you have purchased Savings Plans, Reserved Instances, or On-Demand Capacity Reservations (ODCRs), you want to prioritize this reserved capacity before using standard on-demand or spot instances. This blueprint demonstrates how to configure Karpenter to prioritize different types of reserved capacity, ensuring maximum utilization and cost optimization.

This blueprint covers three main scenarios:
1. **Savings Plans** - Prioritize instance families that match your Savings Plans
2. **Reserved Instances** - Prioritize specific instance types with Reserved Instance commitments  
3. **On-Demand Capacity Reservations (ODCRs)** - Utilize native ODCR support with the `reserved` capacity type

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* For Savings Plans/Reserved Instances: A list of instance types or families that match your reservations, along with the total number of vCPUs reserved.
* For ODCRs: Active On-Demand Capacity Reservations in your AWS account and Karpenter v1.3+ with the `ReservedCapacity` feature gate enabled.
* A `default` Karpenter `NodePool` as that's the one we'll use in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.

## Scenario 1: Savings Plans Priority

If you have Savings Plans for specific instance families (e.g., 20 vCPUs for `c5` family):

**Scenario:** You purchased a Savings Plan covering 20 vCPUs of c5 instances. You want Karpenter to use those discounted c5 instances first, then fall back to regular pricing for any additional capacity needed.

### Configuration

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: savings-plans
spec:
  limits:
    cpu: "20" # Match your Savings Plan capacity
  template:
    metadata:
      labels:
        intent: apps
    spec:
      requirements:
      - key: karpenter.k8s.aws/instance-family
        operator: In
        values:
        - c5  # Instance family matching your Savings Plan
      - key: karpenter.sh/capacity-type
        operator: In
        values:
        - on-demand
  weight: 100  # High priority
```

### Deploy

```sh
kubectl apply -f savings-plans.yaml
kubectl apply -f workload-savings.yaml
```

### Results

**Check the results:**
```sh
# Check nodes and NodePools
kubectl get nodes -o custom-columns="NAME:.metadata.name,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,NODEPOOL:.metadata.labels.karpenter\.sh/nodepool"

# Check capacity usage
kubectl get nodepool savings-plans -o jsonpath='{.status.resources.cpu}' && echo " vCPUs used"
```

**What this demonstrates:**
- **Prioritization works**: c5 instances are provisioned first (savings-plans NodePool)
- **Limits enforced**: Capacity stays under the 20 vCPU limit
- **Fallback works**: Additional pods use default NodePool when savings-plans capacity is reached

**How it works:** Karpenter uses [weighted NodePools](https://karpenter.sh/docs/concepts/scheduling/#weighted-nodepools) - higher weight (100) prioritizes c5 instances first, `limits.cpu: "20"` prevents exceeding Savings Plan capacity, remaining pods use default NodePool.

### Cleanup

```sh
kubectl delete -f savings-plans.yaml -f workload-savings.yaml
```

## Scenario 2: Reserved Instances Priority

If you have Reserved Instances for specific instance types:

### Configuration

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: reserved-instances
spec:
  template:
    metadata:
      labels:
        intent: apps
    spec:
      requirements:
      - key: node.kubernetes.io/instance-type
        operator: In
        values:
        - c5.xlarge  # Specific Reserved Instance types
        - c5.2xlarge
      - key: karpenter.sh/capacity-type
        operator: In
        values:
        - on-demand
  weight: 100
```

### Deploy

```sh
kubectl apply -f reserved-instances.yaml
kubectl apply -f workload-reserved.yaml
```

### Results

**Check the results:**
```sh
kubectl get nodes -o custom-columns="NAME:.metadata.name,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,NODEPOOL:.metadata.labels.karpenter\.sh/nodepool"
```

**What this demonstrates:**
- **Reserved Instance types prioritized**: c5.xlarge and c5.2xlarge are used first (reserved-instances NodePool)
- **Prioritization**: Higher weight ensures Reserved Instance types are chosen over other instance types

**How it works:** Karpenter uses [weighted NodePools](https://karpenter.sh/docs/concepts/scheduling/#weighted-nodepools) - higher weight (100) prioritizes your Reserved Instance types first, maximizing your cost savings by using discounted instances whenever possible.

### Cleanup

```sh
kubectl delete -f reserved-instances.yaml -f workload-reserved.yaml
```

## Scenario 3: On-Demand Capacity Reservations (ODCRs)

If you have active ODCRs and want to use native ODCR support:

**Scenario:** You need guaranteed capacity for critical workloads during peak traffic or launch events. You've created On-Demand Capacity Reservations to ensure instances are always available when needed. You want Karpenter to automatically use these reserved instances first, with seamless fallback to regular on-demand when reservations are full.

### Configuration

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: odcr-nodeclass
spec:
  capacityReservationSelectorTerms:
  - tags:
      intent: apps
  # Or select by specific ODCR ID:
  # - id: cr-1234567890abcdef0
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: odcr-priority
spec:
  template:
    metadata:
      labels:
        intent: apps
    spec:
      nodeClassRef:
        name: odcr-nodeclass
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["reserved", "on-demand"]  # Reserved first, on-demand fallback
```

### Deploy

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

Then deploy the ODCR scenario:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" odcr.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" odcr.yaml
kubectl apply -f odcr.yaml
kubectl apply -f workload-odcr.yaml
```

### Results

**Check the results:**
```sh
kubectl get nodes -L karpenter.sh/capacity-type,karpenter.k8s.aws/capacity-reservation-id

# Check Karpenter logs to see reserved capacity attempted first
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=50 | grep -E "replacement-nodes.*reserved|launched.*capacity-type"
```

**What this demonstrates:**
- **Guaranteed capacity**: Instances launch into your reserved capacity first, ensuring availability
- **Native ODCR integration**: Karpenter automatically detects and uses your capacity reservations
- **Zero-downtime scaling**: Seamless fallback to regular on-demand when reservations are full
- **Capacity visibility**: See exactly which instances are using your reserved capacity

**Understanding the logs:**
You should see output like this showing ODCR prioritization in action:
```
"replacement-nodes":[{"capacity-type":"reserved",...}]  # Planned reserved first
"launched nodeclaim"..."capacity-type":"on-demand"     # Fell back to on-demand
```

This proves Karpenter attempted reserved capacity first, then gracefully fell back to on-demand when no matching ODCRs were found.

> **Note:** This example shows fallback behavior because no ODCRs exist with matching tags or IDs. To see actual reserved capacity usage, create an ODCR with matching tags or update the configuration to use a specific ODCR ID.

**How it works:** The `capacityReservationSelectorTerms` in the EC2NodeClass tells Karpenter which ODCRs to use (by tags or ID), then `capacity-type: reserved` prioritizes those reservations first, providing guaranteed capacity and potential cost savings.

### Cleanup

```sh
kubectl delete -f odcr.yaml -f workload-odcr.yaml
```

## Complete Cleanup

To remove all objects from all scenarios:

```sh
kubectl delete -f .
```

## Additional Resources

- [Karpenter ODCR Documentation](https://karpenter.sh/docs/concepts/nodeclasses/#capacity-reservations)
- [AWS Savings Plans](https://aws.amazon.com/savingsplans/)
- [AWS Reserved Instances](https://aws.amazon.com/ec2/pricing/reserved-instances/)
- [On-Demand Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html)