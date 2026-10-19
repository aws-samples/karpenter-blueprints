#!/bin/bash
# Test script for the NVIDIA GPU DRA (product-name selection + GPU Operator) blueprint
# This script validates that the blueprint works as documented in the README
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster (Kubernetes 1.34+ for DRA)
# - Karpenter v1.15+ installed with DRA support enabled (settings.enableDRA=true,
#   or settings.featureGates.DRANVIDIAGPU=true)
# - NVIDIA GPU Operator installed with the GPUCluster resource enabled
#   (clusterPolicy.deployCR=false, gpuCluster.deployCR=true, driver.enabled=false,
#   toolkit.enabled=false)
# - Environment variables set: CLUSTER_NAME, KARPENTER_NODE_IAM_ROLE_NAME
#
# Usage: ./test.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test configuration
TIMEOUT_NODE_READY=300  # 5 minutes
TIMEOUT_PODS_READY=300  # 5 minutes
POLL_INTERVAL=10

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${GREEN}[TEST]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi

    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Check Karpenter DRA support (DRANVIDIAGPU is an AWS-specific feature gate,
    # surfaced via the AWS_FEATURE_GATES env var, not the core FEATURE_GATES one)
    AWS_FEATURE_GATES=$(kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_FEATURE_GATES")].value}' 2>/dev/null || echo "")
    if [[ ! "$AWS_FEATURE_GATES" == *"DRANVIDIAGPU=true"* ]]; then
        log_error "Karpenter DRA support (DRANVIDIAGPU AWS feature gate) is not enabled"
        log_info "Enable it with: --set settings.enableDRA=true (requires Karpenter v1.15+)"
        exit 1
    fi

    # Check the GPUCluster resource is ready (NVIDIA GPU Operator managing the DRA driver)
    GPUCLUSTER_STATUS=$(kubectl get gpucluster gpu-cluster -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    if [[ "$GPUCLUSTER_STATUS" != "ready" ]]; then
        log_error "GPUCluster 'gpu-cluster' is not ready (status: '$GPUCLUSTER_STATUS')"
        log_info "Install the GPU Operator first. See the README section 'Install the NVIDIA GPU Operator'"
        exit 1
    fi

    # Check the NVIDIA DRA driver DeviceClass exists
    if ! kubectl get deviceclass gpu.nvidia.com &> /dev/null; then
        log_error "DeviceClass 'gpu.nvidia.com' not found. Install the NVIDIA GPU Operator first."
        exit 1
    fi

    if [ -z "$CLUSTER_NAME" ]; then
        export CLUSTER_NAME="karpenter-blueprints"
        log_warn "CLUSTER_NAME not set, using default: $CLUSTER_NAME"
    fi
    if [ -z "$KARPENTER_NODE_IAM_ROLE_NAME" ]; then
        export KARPENTER_NODE_IAM_ROLE_NAME="karpenter-blueprints"
        log_warn "KARPENTER_NODE_IAM_ROLE_NAME not set, using default: $KARPENTER_NODE_IAM_ROLE_NAME"
    fi

    log_info "Using cluster: $CLUSTER_NAME, IAM role: $KARPENTER_NODE_IAM_ROLE_NAME"
    log_info "Prerequisites check passed"
}

wait_for_nodeclaims() {
    local label_selector=$1
    local expected_count=$2
    local timeout=$TIMEOUT_NODE_READY
    local elapsed=0

    log_info "Waiting for $expected_count nodeclaim(s) with selector '$label_selector' to be ready..."

    while [ $elapsed -lt $timeout ]; do
        ready_count=$(kubectl get nodeclaims -l "$label_selector" --no-headers 2>/dev/null | grep -c "True" || true)
        ready_count=${ready_count:-0}
        ready_count=$((ready_count + 0))
        if [ "$ready_count" -ge "$expected_count" ]; then
            log_info "$ready_count nodeclaim(s) ready"
            return 0
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for nodeclaims (expected $expected_count, got $ready_count)"
    kubectl get nodeclaims -l "$label_selector" 2>/dev/null || true
    return 1
}

wait_for_pod_running() {
    local pod_name=$1
    local timeout=$TIMEOUT_PODS_READY
    local elapsed=0

    log_info "Waiting for pod '$pod_name' to be Running..."

    while [ $elapsed -lt $timeout ]; do
        phase=$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$phase" == "Running" ]; then
            log_info "Pod '$pod_name' is Running"
            return 0
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for pod '$pod_name' (last phase: $phase)"
    kubectl describe pod "$pod_name" 2>/dev/null | grep -A 10 "Events:" || true
    return 1
}

cleanup() {
    log_info "Cleaning up GPU DRA product-name resources..."
    kubectl delete pod gpu-dra-demo --ignore-not-found=true 2>/dev/null || true
    kubectl delete resourceclaimtemplate gpu-a10g --ignore-not-found=true 2>/dev/null || true
    kubectl delete nodepool gpu-dra --ignore-not-found=true 2>/dev/null || true
    kubectl delete ec2nodeclass gpu-dra --ignore-not-found=true 2>/dev/null || true
    sleep 15
}

generate_manifests() {
    log_info "Generating manifests..."

    cat << EOF > /tmp/gpu-dra-nodeclass.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-dra
spec:
  amiSelectorTerms:
  - alias: bottlerocket@latest
  role: "$KARPENTER_NODE_IAM_ROLE_NAME"
  instanceStorePolicy: RAID0
  userData: |
    [settings.kubelet-device-plugins.nvidia]
    enabled = false
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: $CLUSTER_NAME
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: $CLUSTER_NAME
EOF

    cat << EOF > /tmp/gpu-dra-nodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-dra
spec:
  limits:
    nodes: 1
  template:
    metadata:
      labels:
        nvidia.com/gpu.present: "true"
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        name: gpu-dra
        kind: EC2NodeClass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["g"]
        - key: karpenter.k8s.aws/instance-gpu-manufacturer
          operator: In
          values: ["nvidia"]
      expireAfter: Never
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
EOF

    cat << EOF > /tmp/resourceclaim-gpu-a10g.yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: gpu-a10g
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
          selectors:
          - cel:
              expression: |-
                device.attributes["gpu.nvidia.com"].productName == "NVIDIA A10G"
EOF

    cat << EOF > /tmp/workload.yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-dra-demo
  labels:
    app: gpu-dra-demo
spec:
  nodeSelector:
    karpenter.sh/nodepool: gpu-dra
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  restartPolicy: Always
  containers:
    - name: gpu-demo
      image: public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
      command: ["/bin/sh", "-c", "nvidia-smi --query-gpu=name,uuid --format=csv,noheader; sleep infinity"]
      resources:
        claims:
        - name: gpu
  resourceClaims:
    - name: gpu
      resourceClaimTemplateName: gpu-a10g
EOF
}

test_provision() {
    log_test "=== GPU DRA Product-Name Selection (GPU Operator) ==="

    cleanup
    generate_manifests

    log_info "Deploying EC2NodeClass, NodePool, ResourceClaimTemplate, and workload..."
    kubectl apply -f /tmp/gpu-dra-nodeclass.yaml
    kubectl apply -f /tmp/gpu-dra-nodepool.yaml
    kubectl apply -f /tmp/resourceclaim-gpu-a10g.yaml
    kubectl apply -f /tmp/workload.yaml

    # With just-in-time DRA, Karpenter provisions a node only in response to the
    # pending DRA pod, so wait for the nodeclaim after deploying the workload.
    if ! wait_for_nodeclaims "karpenter.sh/nodepool=gpu-dra" 1; then
        log_error "❌ FAILED: GPU node was not provisioned for the pending DRA pod"
        cleanup
        return 1
    fi

    # Verify the instance has an A10G (any g5 size satisfies the claim)
    instance_type=$(kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-dra -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")
    log_info "Instance type: $instance_type"
    if [[ "$instance_type" == g5.* ]]; then
        log_test "✅ PASSED: Karpenter chose a g5 instance (A10G GPU) ($instance_type)"
    else
        log_error "❌ FAILED: Expected a g5.* instance (A10G GPU), got $instance_type"
        cleanup
        return 1
    fi

    # Verify a ResourceSlice is published for the node (DRA driver advertising the GPU)
    slice_count=$(kubectl get resourceslice --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$slice_count" -ge 1 ]; then
        log_test "✅ PASSED: DRA ResourceSlice(s) published ($slice_count)"
    else
        log_error "❌ FAILED: No ResourceSlice published; DRA driver may not be advertising the GPU"
        cleanup
        return 1
    fi

    if ! wait_for_pod_running "gpu-dra-demo"; then
        log_error "❌ FAILED: Workload pod did not reach Running"
        cleanup
        return 1
    fi
    log_test "✅ PASSED: gpu-dra-demo pod is Running"

    # Verify the Pod's GPU matches the productName selector (A10G)
    log_info "Checking GPU product name reported by the pod..."
    sleep 10  # give the container a moment to emit its nvidia-smi output
    gpu_output=$(kubectl logs gpu-dra-demo 2>/dev/null || echo "")
    log_info "nvidia-smi output: $gpu_output"
    if [[ "$gpu_output" == *"A10G"* ]]; then
        log_test "✅ PASSED: Pod was allocated an NVIDIA A10G GPU (productName selector confirmed)"
    else
        log_error "❌ FAILED: Expected an A10G GPU in nvidia-smi output, got: $gpu_output"
        cleanup
        return 1
    fi

    log_test "=== ALL TESTS PASSED ==="
    return 0
}

main() {
    local exit_code=0

    check_prerequisites
    test_provision || exit_code=1
    cleanup

    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi

    exit $exit_code
}

main "$@"
