#!/bin/bash
# Test script for the Static NodePool blueprint
# This script validates that the blueprint works as documented in the README
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter installed with StaticCapacity feature gate enabled
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

    # Check StaticCapacity feature gate
    FEATURE_GATES=$(kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_GATES")].value}' 2>/dev/null || echo "")
    if [[ ! "$FEATURE_GATES" == *"StaticCapacity=true"* ]]; then
        log_error "StaticCapacity feature gate is not enabled in Karpenter"
        log_info "Enable it with: FEATURE_GATES=StaticCapacity=true"
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

cleanup() {
    log_info "Cleaning up static capacity resources..."
    kubectl delete nodepool gpu-static --ignore-not-found=true 2>/dev/null || true
    kubectl delete ec2nodeclass gpu-static --ignore-not-found=true 2>/dev/null || true
    sleep 15
}

generate_manifests() {
    log_info "Generating manifests..."

    cat << EOF > /tmp/static-nodeclass.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-static
spec:
  amiSelectorTerms:
  - alias: al2023@latest
  role: "$KARPENTER_NODE_IAM_ROLE_NAME"
  networkInterfaces:
  - networkCardIndex: 0
    deviceIndex: 0
    interfaceType: "interface"
  - networkCardIndex: 0
    deviceIndex: 1
    interfaceType: "efa-only"
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: $CLUSTER_NAME
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: $CLUSTER_NAME
  instanceStorePolicy: RAID0
EOF

    cat << EOF > /tmp/static-nodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-static
spec:
  replicas: 1
  limits:
    nodes: 2
  template:
    metadata:
      labels:
        capacity-type: gpu-static
        nvidia.com/gpu.present: "true"
        vpc.amazonaws.com/efa.present: "true"
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        name: gpu-static
        kind: EC2NodeClass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["g6e.8xlarge"]
      expireAfter: Never
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
EOF
}

test_provision() {
    log_test "=== Static GPU Node Provisioning ==="

    cleanup
    generate_manifests

    log_info "Deploying EC2NodeClass and NodePool with replicas: 1..."
    kubectl apply -f /tmp/static-nodeclass.yaml
    kubectl apply -f /tmp/static-nodepool.yaml

    if ! wait_for_nodeclaims "karpenter.sh/nodepool=gpu-static" 1; then
        log_error "❌ FAILED: Static GPU nodes were not provisioned"
        cleanup
        return 1
    fi

    # Verify node count matches replicas
    node_count=$(kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-static --no-headers 2>/dev/null | grep -c "True" || echo "0")
    if [ "$node_count" -eq 1 ]; then
        log_test "✅ PASSED: 1 static GPU node provisioned matching replicas: 1"
    else
        log_error "❌ FAILED: Expected 1 node, got $node_count"
        cleanup
        return 1
    fi

    # Verify instance type
    instance_type=$(kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-static -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")
    log_info "Instance type: $instance_type"
    if [[ "$instance_type" == g6e* ]]; then
        log_test "✅ PASSED: Correct instance type ($instance_type)"
    else
        log_error "❌ FAILED: Expected g6e.8xlarge, got $instance_type"
        cleanup
        return 1
    fi

    # Verify capacity type is spot or on-demand
    capacity_type=$(kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-static -o jsonpath='{.items[0].metadata.labels.karpenter\.sh/capacity-type}' 2>/dev/null || echo "unknown")
    log_info "Capacity type: $capacity_type"
    if [[ "$capacity_type" == "on-demand" ]]; then
        log_test "✅ PASSED: Valid capacity type ($capacity_type)"
    else
        log_error "❌ FAILED: Expected on-demand, got $capacity_type"
        cleanup
        return 1
    fi

    # Verify NodePool status.nodes
    status_nodes=$(kubectl get nodepool gpu-static -o jsonpath='{.status.nodes}' 2>/dev/null || echo "0")
    log_info "NodePool status.nodes: $status_nodes"
    if [ "$status_nodes" -eq 1 ]; then
        log_test "✅ PASSED: NodePool status.nodes reports 1"
    else
        log_warn "⚠️  NodePool status.nodes reports $status_nodes (may take time to converge)"
    fi

    # Verify nodes have the correct label
    labeled_count=$(kubectl get nodes -l capacity-type=gpu-static --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$labeled_count" -ge 1 ]; then
        log_test "✅ PASSED: Node has capacity-type=gpu-static label"
    else
        log_error "❌ FAILED: Expected 1 labeled node, got $labeled_count"
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
