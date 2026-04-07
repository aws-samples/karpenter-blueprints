# Karpenter OSS to EKS Auto Mode Migration Summary

This document summarizes the migration of Karpenter OSS blueprints (using `EC2NodeClass` + `NodePool`) to EKS Auto Mode equivalents (using `NodeClass` + `NodePool`).

## Migration Summary Table

| # | Blueprint | Status | Notes |
|---|-----------|--------|-------|
| 1 | `disruption-budgets` | ✅ Migrated | Fully migratable. EC2NodeClass → NodeClass, label prefixes updated, expireAfter capped to 336h. |
| 2 | `od-spot-split` | ✅ Migrated | Two NodePools (on-demand + spot) referencing default NodeClass. Label prefixes updated. |
| 3 | `batch-jobs` | ✅ Migrated | Workload-only (Deployments + Jobs). Added `eks.amazonaws.com/compute-type: auto`. |
| 4 | `graviton` | ✅ Migrated | Workload-only. Added `eks.amazonaws.com/compute-type: auto`. |
| 5 | `ha-az-nodes` | ✅ Migrated | Workload-only. Added `eks.amazonaws.com/compute-type: auto`. |
| 6 | `overprovision` | ✅ Migrated | Workload-only. Replaced `karpenter.k8s.aws/` nodeAffinity labels. Added `eks.amazonaws.com/compute-type: auto`. |
| 7 | `stateful` | ✅ Migrated | StorageClass/PVC + workload. Added `eks.amazonaws.com/compute-type: auto` to workload. |
| 8 | `node-reserved-headroom` | ✅ Migrated | DaemonSet + PriorityClasses + workload. Copied as-is (nodeSelectors are commented out). |
| 9 | `multi-ebs` | ⚠️ Partially Migrated | Multiple `blockDeviceMappings` — only data partition size (100Gi) mapped to `ephemeralStorage.size`. Additional EBS volumes must be managed separately. |
| 10 | `node-overlay` | ⚠️ Partially Migrated | GPU NodeClass uses `userData` for time-slicing (NOT supported in Auto Mode). NodeOverlay resources and other NodePools migrated with label prefix updates. |
| 11 | `reserved-capacity` | ⚠️ Partially Migrated | ODCR NodeClass uses `capacityReservationSelectorTerms` (NOT supported in Auto Mode). Other NodePools (reserved-instances, savings-plans, migration) fully migrated. |
| 12 | `soci-snapshotter` | ⚠️ Partially Migrated | 2 of 3 NodeClasses use `userData` + `instanceStorePolicy` for SOCI snapshotter (NOT supported). `non-soci-snapshotter` NodeClass fully migrated. |
| 13 | `dynamic-disk-ebs-volume` | ⚠️ Partially Migrated | EC2NodeClass uses `userData` for dynamic EBS resizing (NOT supported). NodeClass transformed with limitations documented. Workload labels updated. |
| 14 | `update-nodes-with-drift` | ⚠️ Partially Migrated | Uses custom AMI IDs in `amiSelectorTerms` (NOT supported in Auto Mode). NodeClass transformed with limitations documented. |
| 15 | `custom-ami` | ❌ Not Migratable | Entire blueprint relies on custom AMI name selectors. Auto Mode does not support custom AMI selection. |
| 16 | `userdata` | ❌ Not Migratable | Entire blueprint relies on custom `userData` bootstrap scripts. Auto Mode does not support `userData`. |
| 17 | `nvidia-gpu-workload` | ❌ Not Migratable | Blueprint not included in migration scope (not specified in transformation plan). |

---

## Transformation Rules Applied

### 1. EC2NodeClass → NodeClass
- `apiVersion`: `karpenter.k8s.aws/v1` → `eks.amazonaws.com/v1`
- `kind`: `EC2NodeClass` → `NodeClass`
- **Removed fields**: `amiFamily`, `amiSelectorTerms`, `role`, `userData`, `blockDeviceMappings`, `metadataOptions`, `detailedMonitoring`, `instanceStorePolicy`, `instanceProfile`, `associatePublicIPAddress`, `context`, `capacityReservationSelectorTerms`
- **Kept fields**: `subnetSelectorTerms`, `securityGroupSelectorTerms`, `tags`
- **Added**: `ephemeralStorage.size` (mapped from `blockDeviceMappings` root volume, or `"20Gi"` default)

### 2. NodePool nodeClassRef
- `group`: `karpenter.k8s.aws` → `eks.amazonaws.com`
- `kind`: `EC2NodeClass` → `NodeClass`

### 3. Instance Label Prefixes
All `karpenter.k8s.aws/instance-*` labels replaced with `eks.amazonaws.com/instance-*` equivalents in NodePool requirements, NodeOverlay requirements, and workload `nodeSelector`/`nodeAffinity`.

### 4. expireAfter
Auto Mode enforces a maximum node lifetime of **336 hours (14 days)**. Values exceeding 336h were capped. Values not set were defaulted to `336h`.

### 5. Workload nodeSelector
Added `eks.amazonaws.com/compute-type: auto` to workload `nodeSelector` for all Deployments, Jobs, and StatefulSets that should run on Auto Mode nodes.

---

## Limitation Details

### 1. Custom AMI (`amiSelectorTerms` with custom AMI IDs or names)
**Affected blueprints**: `custom-ami`, `update-nodes-with-drift`

Auto Mode fully manages AMI selection. You cannot specify custom AMI IDs, names, or aliases. AMI updates and patching are handled automatically by AWS.

**Alternative**: If you need custom node configurations, consider using EKS managed node groups with custom launch templates instead of Auto Mode for those specific workloads.

### 2. userData (Custom Bootstrap Scripts)
**Affected blueprints**: `userdata`, `dynamic-disk-ebs-volume`, `node-overlay` (GPU time-slicing), `soci-snapshotter`

Auto Mode does not support custom `userData` or bootstrap scripts. Node configuration is fully managed by AWS.

**Alternatives**:
- For GPU time-slicing: Use the NVIDIA GPU Operator or Kubernetes Device Plugin configurations applied at the cluster level.
- For SOCI snapshotter: Wait for native Auto Mode support or use managed node groups.
- For EBS dynamic resizing: Use Kubernetes Persistent Volumes with dynamic provisioning via the EBS CSI driver.

### 3. instanceStorePolicy (RAID0)
**Affected blueprints**: `soci-snapshotter`, `dynamic-disk-ebs-volume`

Auto Mode does not support configuring instance store RAID policies via NodeClass.

**Alternative**: Instance store disks are available but RAID configuration must be handled at the OS level if supported by the Auto Mode AMI, or use EBS-backed storage instead.

### 4. blockDeviceMappings (Multiple Volumes)
**Affected blueprints**: `multi-ebs`, `soci-snapshotter` (Bottlerocket variant)

Only the root/data volume size can be mapped to `ephemeralStorage.size`. Additional EBS volumes specified in `blockDeviceMappings` have no Auto Mode equivalent.

**Alternative**: Use Kubernetes Persistent Volumes with the EBS CSI driver for additional storage needs. Define `PersistentVolumeClaim` resources and mount them in your pods.

### 5. capacityReservationSelectorTerms (ODCR)
**Affected blueprints**: `reserved-capacity` (ODCR NodeClass)

On-Demand Capacity Reservations (ODCR) selection via `capacityReservationSelectorTerms` is not available in Auto Mode NodeClass.

**Alternative**: Use the `karpenter.sh/capacity-type: reserved` requirement in the NodePool to hint at reserved capacity usage. Consult AWS documentation for Auto Mode + ODCR integration updates.

### 6. metadataOptions
**Affected blueprints**: `dynamic-disk-ebs-volume`

Auto Mode enforces IMDSv2 (Instance Metadata Service v2) by default. The `metadataOptions` field is not configurable.

**Note**: This is generally a security improvement. IMDSv2 requires token-based access to instance metadata, which is the recommended best practice.

---

## Access Entry Requirement

When creating a **custom NodeClass** in EKS Auto Mode, you must create an EKS Access Entry to allow the node IAM role to join the cluster. This is required for any NodeClass that is not the default `system` NodeClass.

```bash
# Step 1: Create the access entry for the node role
aws eks create-access-entry \
  --cluster-name <cluster-name> \
  --principal-arn <node-role-arn> \
  --type EC2

# Step 2: Associate the Auto Mode node policy
aws eks associate-access-policy \
  --cluster-name <cluster-name> \
  --principal-arn <node-role-arn> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy \
  --access-scope type=cluster
```

**Important notes**:
- Replace `<cluster-name>` with your EKS cluster name.
- Replace `<node-role-arn>` with the ARN of the IAM role used by the Auto Mode nodes.
- The `AmazonEKSAutoNodePolicy` grants the necessary permissions for nodes to register with the cluster and pull container images.
- Each custom NodeClass that uses a different IAM role needs its own access entry.

---

## Files Not Migrated

The following blueprint directories were **not** created in `blueprints-automode/` because their entire functionality depends on features not available in Auto Mode:

| Blueprint | Reason |
|-----------|--------|
| `custom-ami` | Relies entirely on custom AMI name selectors (`amiSelectorTerms` with `name` field). Auto Mode manages AMI selection. |
| `userdata` | Entire blueprint demonstrates custom `userData` bootstrap scripts. Auto Mode does not support `userData`. |
| `nvidia-gpu-workload` | Not included in migration scope. |

---

## Migration Checklist

Before applying the migrated manifests:

- [ ] Ensure your EKS cluster has Auto Mode enabled
- [ ] Create EKS Access Entries for any custom NodeClass IAM roles (see above)
- [ ] Review `ephemeralStorage.size` values to ensure they meet your workload requirements
- [ ] For partially migrated blueprints, review the limitation comments in each YAML file
- [ ] Test workloads in a non-production environment first
- [ ] Verify that `expireAfter` values (max 336h) align with your node lifecycle requirements
- [ ] For GPU workloads: ensure the NVIDIA GPU Operator or equivalent is installed if time-slicing is needed
- [ ] For storage workloads: ensure the EBS CSI driver is installed and configured
