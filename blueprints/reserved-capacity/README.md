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

## Deploy

### Scenario 1: Savings Plans Priority

If you have Savings Plans for specific instance families (e.g., 20 vCPUs for `c4` family):

```sh
kubectl apply -f savings-plans.yaml
kubectl apply -f workload-savings.yaml
```

### Scenario 2: Reserved Instances Priority  

If you have Reserved Instances for specific instance types:

```sh
kubectl apply -f reserved-instances.yaml
kubectl apply -f workload-reserved.yaml
```

### Scenario 3: On-Demand Capacity Reservations (ODCRs)

If you have active ODCRs and want to use native ODCR support:

```sh
kubectl apply -f odcr-nodeclass.yaml
kubectl apply -f odcr-nodepool.yaml
kubectl apply -f workload-odcr.yaml
```

## Configuration Details

### Savings Plans Configuration

Uses `weight` and `limits` to prioritize instance families matching your Savings Plans:

- `weight: 100` - High priority for this NodePool
- `limits.cpu: "20"` - Limit capacity to match your Savings Plan
- Instance family constraint (e.g., `c4`)

### Reserved Instances Configuration

Similar to Savings Plans but targets specific instance types rather than families.

### ODCR Configuration

Uses native ODCR support with:

- `capacityReservationSelectorTerms` in EC2NodeClass to select specific ODCRs
- `karpenter.sh/capacity-type: reserved` in NodePool requirements
- Automatic fallback to `on-demand` when ODCRs are exhausted

## Results

### Savings Plans/Reserved Instances

You'll see nodes launched in priority order:
1. First: Instances matching your Savings Plans/Reserved Instances (up to limits)
2. Then: Fallback to default NodePool for additional capacity

### ODCRs

You'll see:
1. `capacity-type: reserved` for instances using ODCRs
2. `capacity-type: on-demand` for fallback instances
3. Karpenter logs showing ODCR prioritization behavior

Check Karpenter logs to see the prioritization:

```sh
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100 | grep "replacement-nodes"
```

## Cleanup

To remove all objects created:

```sh
kubectl delete -f .
```

## Additional Resources

- [Karpenter ODCR Documentation](https://karpenter.sh/docs/concepts/nodeclasses/#capacity-reservations)
- [AWS Savings Plans](https://aws.amazon.com/savingsplans/)
- [AWS Reserved Instances](https://aws.amazon.com/ec2/pricing/reserved-instances/)
- [On-Demand Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html)