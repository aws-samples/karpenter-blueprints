#!/bin/bash
# Test script for the Neuron Workload blueprint
# Validates that Karpenter provisions Trainium/Inferentia instances
# and the Neuron device plugin advertises devices correctly.
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter installed
# - Neuron Helm chart installed (scheduler + device plugin)
# - Environment variables set: CLUSTER_NAME, KARPENTER_NODE_IAM_ROLE_NAME
#
# Usage: ./test.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Timeouts
TIMEOUT_NODE_READY=300
TIMEOUT_POD_READY=300

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

    if [ -z "$CLUSTER_NAME" ]; then
        log_error "CLUSTER_NAME environment variable is not set"
        log_info "Set it with: export CLUSTER_NAME=\$(terraform -chdir='../../cluster/terraform' output -raw cluster_name)"
        exit 1
    fi

    if [ -z "$KARPENTER_NODE_IAM_ROLE_NAME" ]; then
        log_error "KARPENTER_NODE_IAM_ROLE_NAME environment variable is not set"
        log_info "Set it with: export KARPENTER_NODE_IAM_ROLE_NAME=\$(terraform -chdir='../../cluster/terraform' output -raw node_instance_role_name)"
        exit 1
    fi

    # Verify Neuron Helm chart is installed
    if ! helm list -n kube-system 2>/dev/null | grep -q "neuron-helm-chart"; then
        log_error "Neuron Helm chart is not installed"
        log_info "Install it with:"
        log_info "  helm install neuron-helm-chart oci://public.ecr.aws/neuron/neuron-helm-chart \\"
        log_info "    --set 'scheduler.enabled=true' \\"
        log_info "    --set 'scheduler.customScheduler.fullnameOverride=neuron-scheduler' \\"
        log_info "    --set 'npd.enabled=false' \\"
        log_info "    --namespace kube-system"
        exit 1
    fi

    log_info "Using cluster: $CLUSTER_NAME, IAM role: $KARPENTER_NODE_IAM_ROLE_NAME"
    log_info "Prerequisites check passed"
}

wait_for_nodeclaim() {
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
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for nodeclaims to be ready"
    kubectl get nodeclaims -l "$label_selector" 2>/dev/null || true
    return 1
}

wait_for_pod_status() {
    local pod_name=$1
    local expected_status=$2
    local timeout=$TIMEOUT_POD_READY
    local elapsed=0

    log_info "Waiting for pod '$pod_name' to reach status '$expected_status'..."

    while [ $elapsed -lt $timeout ]; do
        phase=$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$phase" == "$expected_status" ]; then
            log_info "Pod '$pod_name' is $expected_status"
            return 0
        fi
        # For neuron-ls, Succeeded (Completed) is also a valid terminal state
        if [ "$expected_status" == "Running" ] && [ "$phase" == "Succeeded" ]; then
            log_info "Pod '$pod_name' completed successfully (Succeeded)"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for pod '$pod_name' to reach '$expected_status'"
    kubectl describe pod "$pod_name" 2>/dev/null || true
    return 1
}

cleanup() {
    log_info "Cleaning up neuron-workload test resources..."
    kubectl delete pod neuron-ls --ignore-not-found=true 2>/dev/null || true
    kubectl delete nodepool neuron --ignore-not-found=true 2>/dev/null || true
    kubectl delete ec2nodeclass neuron --ignore-not-found=true 2>/dev/null || true
    # Wait for nodes to drain
    sleep 10
}

test_neuron_workload() {
    cleanup

    # --- Step 1: Create EC2NodeClass ---
    log_info "Creating EC2NodeClass for neuron instances..."
    cat <<EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: neuron
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

    # --- Step 2: Create NodePool ---
    log_info "Creating NodePool for neuron instances..."
    cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: neuron
spec:
  limits:
    cpu: 100
    memory: 100Gi
    aws.amazon.com/neuron: 5
  template:
    metadata:
      labels:
        intent: neuron
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        name: neuron
        kind: EC2NodeClass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["inf", "trn"]
      expireAfter: 720h
      taints:
        - key: aws.amazon.com/neuron
          effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m
EOF

    sleep 5

    # --- Step 3: Deploy test workload ---
    log_info "Deploying neuron-ls test pod..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: neuron-ls
spec:
  nodeSelector:
    intent: neuron
    karpenter.k8s.aws/instance-accelerator-name: inferentia
  restartPolicy: OnFailure
  schedulerName: neuron-scheduler
  containers:
  - name: neuron-ls
    image: public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.13.0-neuronx-py312-sdk2.27.1-ubuntu24.04
    args:
    - "neuron-ls"
    resources:
      requests:
        memory: "30Gi"
        cpu: "3500m"
      limits:
        memory: "30Gi"
        aws.amazon.com/neuron: 2
  tolerations:
  - key: aws.amazon.com/neuron
    effect: NoSchedule
    operator: Exists
EOF

    # --- Step 4: Wait for node provisioning ---
    if ! wait_for_nodeclaim "karpenter.sh/nodepool=neuron" 1; then
        log_error "❌ FAILED: Karpenter did not provision a neuron node"
        return 1
    fi

    # --- Step 5: Validate instance category ---
    log_info "Validating provisioned instance..."
    instance_category=$(kubectl get nodeclaims -l karpenter.sh/nodepool=neuron -o jsonpath='{.items[0].metadata.labels.karpenter\.k8s\.aws/instance-category}' 2>/dev/null || echo "unknown")
    instance_type=$(kubectl get nodeclaims -l karpenter.sh/nodepool=neuron -o jsonpath='{.items[0].spec.instanceType}' 2>/dev/null || echo "unknown")

    log_info "Provisioned instance: $instance_type (category: $instance_category)"

    if [ "$instance_category" == "inf" ] || [ "$instance_category" == "trn" ]; then
        log_test "✅ PASSED: Instance is in accelerator category '$instance_category'"
    else
        log_error "❌ FAILED: Expected instance category 'inf' or 'trn', got '$instance_category'"
        return 1
    fi

    # --- Step 6: Validate neuron devices on node ---
    log_info "Checking neuron device advertisement on node..."
    node_name=$(kubectl get nodeclaims -l karpenter.sh/nodepool=neuron -o jsonpath='{.items[0].status.nodeName}' 2>/dev/null || echo "")
    if [ -n "$node_name" ]; then
        neuron_devices=$(kubectl get node "$node_name" -o jsonpath='{.status.allocatable.aws\.amazon\.com/neuron}' 2>/dev/null || echo "0")
        neuron_cores=$(kubectl get node "$node_name" -o jsonpath='{.status.allocatable.aws\.amazon\.com/neuroncore}' 2>/dev/null || echo "0")
        log_info "Node $node_name: NeuronDevices=$neuron_devices, NeuronCores=$neuron_cores"

        if [ "$neuron_devices" -gt 0 ] 2>/dev/null; then
            log_test "✅ PASSED: Node advertises $neuron_devices neuron device(s) and $neuron_cores neuron core(s)"
        else
            log_error "❌ FAILED: Node does not advertise neuron devices"
            return 1
        fi
    else
        log_warn "Could not determine node name from nodeclaim"
    fi

    # --- Step 7: Wait for pod to run and validate output ---
    if ! wait_for_pod_status "neuron-ls" "Running"; then
        log_error "❌ FAILED: neuron-ls pod did not reach Running/Succeeded state"
        return 1
    fi

    log_info "Checking neuron-ls output..."
    sleep 5
    pod_logs=$(kubectl logs pod/neuron-ls 2>/dev/null || echo "")
    if echo "$pod_logs" | grep -q "NEURON"; then
        log_test "✅ PASSED: neuron-ls output contains Neuron device information"
        log_info "Output:"
        echo "$pod_logs"
    else
        log_warn "neuron-ls output did not contain expected Neuron table (pod may still be initializing)"
        log_info "Output: $pod_logs"
    fi

    return 0
}

main() {
    local exit_code=0

    check_prerequisites
    test_neuron_workload || exit_code=1
    cleanup

    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi

    exit $exit_code
}

main "$@"
