# Karpenter Blueprint: Prioritize Reserved Capacity

> **Note:** This blueprint focuses on Savings Plans, Reserved Instances, and On-Demand Capacity Reservations. EC2 Capacity Blocks are out of scope for this blueprint.

## Purpose

If you have purchased Savings Plans, Reserved Instances, or On-Demand Capacity Reservations (ODCRs), you want to prioritize this reserved capacity before using standard on-demand or spot instances. This blueprint demonstrates how to configure Karpenter to prioritize different types of reserved capacity, ensuring maximum utilization and cost optimization.

> **AWS Recommendation**: We recommend using On-Demand Capacity Reservations (ODCRs) for guaranteed capacity needs, especially as current guidance favors Savings Plans over Reserved Instances. Note that Savings Plans provide cost savings but do not reserve capacity. For capacity guarantees, ODCRs are the preferred approach. See [AWS documentation on capacity reservation differences](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html#capacity-reservations-differences) for more details.

This blueprint covers four main scenarios:
1. **Savings Plans** - Prioritize instance families that match your Savings Plans
2. **Reserved Instances** - Prioritize specific instance types with Reserved Instance commitments  
3. **On-Demand Capacity Reservations (ODCRs)** - Utilize native ODCR support with the `reserved` capacity type
4. **Migrating Existing Workloads** - Transition running workloads from on-demand to reserved capacity

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* For Savings Plans/Reserved Instances: A list of instance types or families that match your reservations, along with the total number of vCPUs reserved.
* For ODCRs: Active On-Demand Capacity Reservations in your AWS account and Karpenter v1.6+ (ReservedCapacity feature gate enabled by default) or v1.3+ with manual feature gate configuration.
* A `default` Karpenter `NodePool` and `EC2NodeClass` deployed in your cluster. If you used the Terraform template in this repository, these are already created for you.

### Feature Gate Configuration (Karpenter < v1.6)

For Karpenter versions prior to v1.6, you must enable the ReservedCapacity feature gate:

```yaml
# In your Karpenter Helm values or deployment
settings:
  featureGates:
    ReservedCapacity: true
```

Or via environment variable:
```yaml
env:
- name: FEATURE_GATES
  value: "ReservedCapacity=true"
```

## Scenario 1: Savings Plans Priority

**Scenario:** You purchased a Savings Plan covering 20 vCPUs of c5 instances. You want Karpenter to use those discounted c5 instances first, then fall back to regular pricing for any additional capacity needed.

### Deploy

```sh
kubectl apply -f savings-plans.yaml
kubectl apply -f workload-savings.yaml
```

### Results

**Check results:**
```sh
kubectl get nodes -o custom-columns="NAME:.metadata.name,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,NODEPOOL:.metadata.labels.karpenter\.sh/nodepool"
kubectl get nodepool savings-plans -o jsonpath='{.status.resources.cpu}' && echo " / 20 vCPUs used"
```

**What this demonstrates:**
- **Prioritization works**: c5 instances are provisioned first (savings-plans NodePool)
- **Capacity limits respected**: savings-plans NodePool reaches its 20 vCPU limit
- **Spillover works**: Additional workload uses default NodePool when savings-plans is at capacity

### Cleanup

```sh
kubectl delete -f savings-plans.yaml -f workload-savings.yaml
```

## Scenario 2: Reserved Instances Priority

**Scenario:** You have Reserved Instances for specific instance types (c5.xlarge, c5.2xlarge) and want to prioritize them over other instance types. The NodePool limits capacity to 16 vCPUs and uses weight 100 for prioritization.

**Key configuration:**
```yaml
spec:
  limits:
    cpu: "16"
  template:
    spec:
      requirements:
      - key: node.kubernetes.io/instance-type
        operator: In
        values:
        - c5.xlarge    # 4 vCPUs
        - c5.2xlarge   # 8 vCPUs
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
kubectl get nodes -l karpenter.sh/nodepool -o custom-columns="NAME:.metadata.name,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,NODEPOOL:.metadata.labels.karpenter\.sh/nodepool"
```

**Expected output:**
```
NAME                                        INSTANCE      NODEPOOL
ip-10-0-x-x.region.compute.internal         c5.2xlarge    reserved-instances
```

**What this demonstrates:**
- **Reserved Instance types prioritized**: c5.xlarge and c5.2xlarge are used first
- **Higher weight ensures prioritization** over other instance types

### Cleanup

```sh
kubectl delete -f reserved-instances.yaml -f workload-reserved.yaml
```

## Scenario 3: On-Demand Capacity Reservations (ODCRs)

### Prerequisites: Creating an ODCR for Testing

> **⚠️ COST WARNING**: ODCRs incur charges whether instances are running or not. You will be billed for reserved capacity even if unused.

**For testing Scenario 3, create a small ODCR first:**

```sh
# Get cluster name, region and AZ from Terraform outputs
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export AWS_REGION=$(terraform -chdir="../../cluster/terraform" output -raw region)
export AZ=$(terraform -chdir="../../cluster/terraform" output -json availability_zones | jq -r '.[0]')

# Create ODCR
aws ec2 create-capacity-reservation \
  --instance-type t3.small \
  --instance-platform Linux/UNIX \
  --availability-zone $AZ \
  --instance-count 2 \
  --tag-specifications 'ResourceType=capacity-reservation,Tags=[{Key=intent,Value=apps},{Key=project,Value='$CLUSTER_NAME'}]' \
  --region $AWS_REGION
```

**Important:** This costs ~$0.0208/hour ($15/month) for 2 × t3.small whether used or not. Delete after testing: `aws ec2 cancel-capacity-reservation --capacity-reservation-id <cr-id>`

**Scenario:** You need guaranteed capacity for critical workloads during peak traffic or launch events. You've created On-Demand Capacity Reservations to ensure instances are always available when needed. You want Karpenter to automatically use these reserved instances first, with seamless fallback to regular on-demand when reservations are full.

### Configuration Options

The EC2NodeClass can select ODCRs in two ways:

**Option 1: Select by tags (recommended)**
```yaml
capacityReservationSelectorTerms:
- tags:
    intent: apps
    project: karpenter-blueprints
```

**Option 2: Select by specific ODCR ID**
```yaml
capacityReservationSelectorTerms:
- id: cr-1234567890abcdef0
```

### Deploy

If you're using the Terraform template provided in this repo, run the following commands to get the cluster name, IAM role name, and availability zone:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
export AZ=$(terraform -chdir="../../cluster/terraform" output -json availability_zones | jq -r '.[0]')
```

Now, make sure you're in this blueprint folder, then run the following commands:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" odcr.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" odcr.yaml
sed -i '' "s/<<AZ>>/$AZ/g" odcr.yaml
kubectl apply -f odcr.yaml
kubectl apply -f workload-odcr.yaml
```

### Results

**Check the results:**
```sh
kubectl get nodes -L karpenter.sh/capacity-type,karpenter.k8s.aws/capacity-reservation-id,topology.kubernetes.io/zone
echo "ODCR Usage:"
aws ec2 describe-capacity-reservations --filters Name=state,Values=active --query 'CapacityReservations[*].[CapacityReservationId,InstanceType,AvailabilityZone,TotalInstanceCount,AvailableInstanceCount]' --output table
```

**Expected output:**
```
NAME                                        CAPACITY-TYPE   CAPACITY-RESERVATION-ID   ZONE
ip-10-0-x-x.region.compute.internal         reserved        cr-01a3e9b00c9e81913      eu-west-2a
ip-10-0-x-x.region.compute.internal         on-demand                                 eu-west-2b

ODCR Usage:
|  cr-01a3e9b00c9e81913  |  t3.small  |  eu-west-2a  |  2  |  1  |  # 1 instance used
```

```sh
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=50 | grep -E "replacement-nodes.*reserved|launched.*capacity-type"
```

**Expected output:**
```
"replacement-nodes":[{"capacity-type":"reserved",...}]  # Planned reserved first
"launched nodeclaim"..."capacity-type":"on-demand"     # Fell back to on-demand
```

**What this demonstrates:**
- **ODCR prioritization**: Karpenter uses reserved capacity first when available
- **Exhaustion handling**: When ODCR is full, automatically falls back to on-demand
- **AZ-specific behavior**: ODCRs only work within their designated availability zone
- **Cost optimization**: Reserved capacity is consumed before on-demand instances

### Cleanup

```sh
kubectl delete -f odcr.yaml -f workload-odcr.yaml
```

## Scenario 4: Migrating Existing Workloads to ODCR

**Scenario:** You have workloads running on regular on-demand instances and want to migrate the same NodePool to use On-Demand Capacity Reservations (ODCRs) without downtime.

### Prerequisites

Ensure you have an active ODCR (from Scenario 3 or existing setup).

### Deploy

**Step 1: Create a stable on-demand NodePool**
```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
export AZ=$(terraform -chdir="../../cluster/terraform" output -json availability_zones | jq -r '.[0]')

sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" migration-nodeclass.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" migration-nodeclass.yaml
sed -i '' "s/<<AZ>>/$AZ/g" migration-nodeclass.yaml
kubectl apply -f migration-nodeclass.yaml
```

**Step 2: Deploy workload to the stable NodePool**
```sh
kubectl apply -f workload-migration.yaml
```

**Step 3: Verify initial on-demand placement**
```sh
kubectl get nodes -L karpenter.sh/capacity-type,karpenter.k8s.aws/capacity-reservation-id,karpenter.sh/nodepool
```


**Expected output:**
```
NAME                                       STATUS   ROLES    AGE   VERSION               CAPACITY-TYPE   CAPACITY-RESERVATION-ID   NODEPOOL
ip-10-0-34-41.eu-west-2.compute.internal   Ready    <none>   18h   v1.34.2-eks-ecaa3a6                                             
ip-10-0-5-48.eu-west-2.compute.internal    Ready    <none>   37s   v1.34.2-eks-ecaa3a6   on-demand                                 reserved-migration
ip-10-0-9-147.eu-west-2.compute.internal   Ready    <none>   18h   v1.34.2-eks-ecaa3a6   
```

### Migration to ODCR

**Step 4: Add ODCR configuration to existing EC2NodeClass**
```sh
kubectl patch ec2nodeclass migration-nodeclass --type='merge' -p='{
  "spec": {
    "capacityReservationSelectorTerms": [{
      "tags": {
        "intent": "apps",
        "project": "'$CLUSTER_NAME'"
      }
    }]
  }
}'
```

**Step 5: Update NodePool to prioritize reserved capacity**
```sh
kubectl patch nodepool reserved-migration --type='merge' -p='{
  "spec": {
    "template": {
      "spec": {
        "requirements": [{
          "key": "karpenter.sh/capacity-type",
          "operator": "In",
          "values": ["reserved", "on-demand"]
        }]
      }
    }
  }
}'
```

**Step 6: Trigger drift to migrate to ODCR**
```sh
kubectl rollout restart deployment migration-workload
```

### Results

**Monitor the migration:**
```sh
kubectl get nodes -L karpenter.sh/capacity-type,karpenter.k8s.aws/capacity-reservation-id,karpenter.sh/nodepool
```

**Expected output after migration:**
```
NAME                     CAPACITY-TYPE   CAPACITY-RESERVATION-ID   NODEPOOL
NAME                                       STATUS     ROLES    AGE    VERSION               CAPACITY-TYPE   CAPACITY-RESERVATION-ID   NODEPOOL
ip-10-0-0-120.eu-west-2.compute.internal   NotReady   <none>   105s   v1.34.2-eks-ecaa3a6   reserved        cr-01a3e9b00c9e81913      reserved-migration
ip-10-0-34-41.eu-west-2.compute.internal   Ready      <none>   18h    v1.34.2-eks-ecaa3a6                                             
ip-10-0-6-17.eu-west-2.compute.internal    Ready      <none>   94s    v1.34.2-eks-ecaa3a6   reserved        cr-01a3e9b00c9e81913      reserved-migration
ip-10-0-9-147.eu-west-2.compute.internal   Ready      <none>   18h    v1.34.2-eks-ecaa3a6
```

**Check ODCR usage:**
```sh
aws ec2 describe-capacity-reservations --filters Name=state,Values=active --query 'CapacityReservations[*].[CapacityReservationId,InstanceType,TotalInstanceCount,AvailableInstanceCount]' --output table
```

**What this demonstrates:**
- **Same NodePool migration**: Existing NodePool migrates from on-demand to reserved capacity
- **Drift-based replacement**: Configuration changes trigger node replacement
- **ODCR utilization**: New nodes use reserved capacity first
- **Zero downtime**: Rolling restart ensures seamless transition

### Cleanup

```sh
kubectl delete -f workload-migration.yaml -f migration-nodeclass.yaml
```

## Complete Cleanup

To remove all objects from all scenarios:

```sh
kubectl delete -f .
```

**Don't forget to cancel any ODCRs you created for testing:**
```sh
# List active ODCRs
aws ec2 describe-capacity-reservations --filters Name=state,Values=active --query 'CapacityReservations[*].[CapacityReservationId,InstanceType,InstanceCount]' --output table

# Cancel ODCR (replace with your ID)
aws ec2 cancel-capacity-reservation --capacity-reservation-id <cr-id>
```

## Additional Resources

- [Karpenter ODCR Documentation](https://karpenter.sh/docs/concepts/nodeclasses/#capacity-reservations)
- [AWS Savings Plans](https://aws.amazon.com/savingsplans/)
- [AWS Reserved Instances](https://aws.amazon.com/ec2/pricing/reserved-instances/)
- [On-Demand Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html)