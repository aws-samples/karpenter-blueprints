#!/bin/bash
# Test script for the kubelet CEL sizing blueprint
# This script validates that the blueprint works as documented in the README
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter v1.15.0+ installed with the NodeClassCEL AWS feature gate enabled
# - Environment variables set: CLUSTER_NAME, KARPENTER_NODE_IAM_ROLE_NAME
#
# Usage: ./test.sh [scenario1|scenario2|all]
#   scenario1: one EC2NodeClass resolves maxPods/kubeReserved/systemReserved per instance size
#   scenario2: an invalid expression is reported on the EC2NodeClass status (no nodes launched)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TIMEOUT_NODECLASS_READY=120
TIMEOUT_NODE_READY=420
RENDERED=/tmp/kubelet-cel-sizing-test.yaml
INVALID_NODECLASS=kubelet-cel-sizing-invalid

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

    if [ -z "$CLUSTER_NAME" ] || [ -z "$KARPENTER_NODE_IAM_ROLE_NAME" ]; then
        log_error "CLUSTER_NAME and KARPENTER_NODE_IAM_ROLE_NAME must be set"
        exit 1
    fi

    AWS_FEATURE_GATES=$(kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_FEATURE_GATES")].value}' 2>/dev/null || echo "")
    if [[ ! "$AWS_FEATURE_GATES" == *"NodeClassCEL=true"* ]]; then
        log_error "NodeClassCEL AWS feature gate is not enabled in Karpenter (requires Karpenter v1.15.0+)"
        log_info "Enable it with: helm upgrade karpenter ... --set 'settings.awsFeatureGates.nodeClassCEL=true'"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

render_manifest() {
    sed -e "s|<<CLUSTER_NAME>>|$CLUSTER_NAME|g" \
        -e "s|<<KARPENTER_NODE_IAM_ROLE_NAME>>|$KARPENTER_NODE_IAM_ROLE_NAME|g" \
        kubelet-cel-sizing.yaml > "$RENDERED"
}

cleanup() {
    log_info "Cleaning up..."
    kubectl delete -f workload.yaml --ignore-not-found=true 2>/dev/null || true
    if [ -f "$RENDERED" ]; then
        kubectl delete -f "$RENDERED" --ignore-not-found=true --wait=false 2>/dev/null || true
    else
        kubectl delete nodepool kubelet-cel-sizing --ignore-not-found=true --wait=false 2>/dev/null || true
        kubectl delete ec2nodeclass kubelet-cel-sizing --ignore-not-found=true --wait=false 2>/dev/null || true
    fi
    kubectl delete ec2nodeclass "$INVALID_NODECLASS" --ignore-not-found=true 2>/dev/null || true
}

# Prints the status of a condition on an EC2NodeClass ("True", "False" or "")
nodeclass_condition() {
    kubectl get ec2nodeclass "$1" -o jsonpath="{.status.conditions[?(@.type==\"$2\")].$3}" 2>/dev/null || echo ""
}

wait_for_nodeclass_ready() {
    local name=$1
    local elapsed=0
    log_info "Waiting for EC2NodeClass '$name' to be Ready..."
    while [ $elapsed -lt $TIMEOUT_NODECLASS_READY ]; do
        if [ "$(nodeclass_condition "$name" Ready status)" == "True" ]; then
            log_info "EC2NodeClass '$name' is Ready"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_error "Timeout waiting for EC2NodeClass '$name' to be Ready"
    kubectl get ec2nodeclass "$name" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
    return 1
}

# Waits for a Ready node in the blueprint NodePool with the given vCPU count, prints its name
wait_for_node() {
    local vcpus=$1
    local elapsed=0
    local selector="karpenter.sh/nodepool=kubelet-cel-sizing,karpenter.k8s.aws/instance-cpu=$vcpus"
    while [ $elapsed -lt $TIMEOUT_NODE_READY ]; do
        local node
        node=$(kubectl get nodes -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | awk '$2=="True"{print $1; exit}')
        if [ -n "$node" ]; then
            echo "$node"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    return 1
}

round_up() { echo $(( ($1 + $2 - 1) / $2 * $2 )); }
max() { if [ "$1" -gt "$2" ]; then echo "$1"; else echo "$2"; fi; }

# CPU quantity ("2", "1830m") -> millicores
cpu_to_milli() {
    local q=$1
    if [[ "$q" == *m ]]; then echo "${q%m}"; else echo $(( q * 1000 )); fi
}

# Memory quantity ("3926584Ki", "1472Mi", "4Gi", bytes) -> KiB
mem_to_ki() {
    local q=$1
    case "$q" in
        *Ki) echo "${q%Ki}" ;;
        *Mi) echo $(( ${q%Mi} * 1024 )) ;;
        *Gi) echo $(( ${q%Gi} * 1024 * 1024 )) ;;
        *)   echo $(( q / 1024 )) ;;
    esac
}

# Checks one node against the values the EC2NodeClass expressions should resolve to.
# Mirrors the expressions in kubelet-cel-sizing.yaml, including Karpenter's rounding
# (cpu up to 10m, memory up to 16Mi).
verify_node() {
    local node=$1
    local failed=0

    local instance_type vcpus memory_mib
    instance_type=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
    vcpus=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.karpenter\.k8s\.aws/instance-cpu}')
    memory_mib=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.karpenter\.k8s\.aws/instance-memory}')

    # maxPods: min(vcpus < 30 ? 110 : 250, ENI prefix capacity). The ENI term never binds
    # for the c/m/r gen 6+ sizes this NodePool allows (a 2-vCPU .large addresses 434 pods).
    local exp_pods
    if [ "$vcpus" -lt 30 ]; then exp_pods=110; else exp_pods=250; fi

    local kube_cpu sys_cpu kube_mem sys_mem
    kube_cpu=$(round_up $(( 60 + vcpus * 5 )) 10)
    sys_cpu=$(round_up "$(max 100 $(( vcpus * 10 )))" 10)
    kube_mem=$(round_up $(( 11 * exp_pods + 255 )) 16)
    sys_mem=$(round_up "$(max 100 $(( memory_mib / 64 )))" 16)
    local exp_cpu_reserved=$(( kube_cpu + sys_cpu ))
    local exp_mem_reserved=$(( kube_mem + sys_mem ))

    local cap_pods cap_cpu alloc_cpu cap_mem alloc_mem
    cap_pods=$(kubectl get node "$node" -o jsonpath='{.status.capacity.pods}')
    cap_cpu=$(cpu_to_milli "$(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}')")
    alloc_cpu=$(cpu_to_milli "$(kubectl get node "$node" -o jsonpath='{.status.allocatable.cpu}')")
    cap_mem=$(mem_to_ki "$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}')")
    alloc_mem=$(mem_to_ki "$(kubectl get node "$node" -o jsonpath='{.status.allocatable.memory}')")
    local cpu_reserved=$(( cap_cpu - alloc_cpu ))
    local mem_reserved=$(( (cap_mem - alloc_mem) / 1024 ))

    log_info "Node $node ($instance_type, ${vcpus} vCPU, ${memory_mib} MiB)"
    log_info "  expected: maxPods=$exp_pods kubeReserved=${kube_cpu}m/${kube_mem}Mi systemReserved=${sys_cpu}m/${sys_mem}Mi"

    if [ "$cap_pods" == "$exp_pods" ]; then
        log_test "  ✅ PASSED: maxPods is $cap_pods"
    else
        log_error "  ❌ FAILED: expected maxPods $exp_pods, node reports $cap_pods"
        failed=1
    fi

    # Allocatable CPU = capacity - kubeReserved - systemReserved (eviction thresholds don't apply to CPU)
    if [ "$cpu_reserved" -eq "$exp_cpu_reserved" ]; then
        log_test "  ✅ PASSED: reserved CPU is ${cpu_reserved}m"
    else
        log_error "  ❌ FAILED: expected ${exp_cpu_reserved}m reserved CPU, node reserves ${cpu_reserved}m"
        failed=1
    fi

    # Allocatable memory also subtracts the hard eviction threshold, so reserved memory is at least
    # kubeReserved + systemReserved
    if [ "$mem_reserved" -ge "$exp_mem_reserved" ]; then
        log_test "  ✅ PASSED: reserved memory is ${mem_reserved}Mi (>= ${exp_mem_reserved}Mi from the expressions)"
    else
        log_error "  ❌ FAILED: expected at least ${exp_mem_reserved}Mi reserved memory, node reserves ${mem_reserved}Mi"
        failed=1
    fi

    return $failed
}

# ============================================================================
# SCENARIO 1: One EC2NodeClass, per-instance-type kubelet sizing
# ============================================================================
test_scenario1() {
    log_test "=== Scenario 1: per-instance-type kubelet sizing ==="
    cleanup
    render_manifest

    kubectl apply -f "$RENDERED"
    wait_for_nodeclass_ready kubelet-cel-sizing || return 1

    if [ "$(nodeclass_condition kubelet-cel-sizing ValidationSucceeded status)" == "True" ]; then
        log_test "✅ PASSED: EC2NodeClass ValidationSucceeded=True"
    else
        log_error "❌ FAILED: EC2NodeClass ValidationSucceeded is not True"
        return 1
    fi

    kubectl apply -f workload.yaml

    local failed=0
    local vcpus node
    for vcpus in 2 32; do
        log_info "Waiting for a ${vcpus}-vCPU node..."
        if ! node=$(wait_for_node "$vcpus"); then
            log_error "❌ FAILED: no Ready ${vcpus}-vCPU node within ${TIMEOUT_NODE_READY}s"
            kubectl get nodeclaims -l karpenter.sh/nodepool=kubelet-cel-sizing 2>/dev/null || true
            failed=1
            continue
        fi
        verify_node "$node" || failed=1
    done

    if [ $failed -eq 0 ]; then
        log_test "✅ Scenario 1 PASSED"
    else
        log_error "❌ Scenario 1 FAILED"
    fi
    return $failed
}

# ============================================================================
# SCENARIO 2: An invalid expression is surfaced on the EC2NodeClass status
# ============================================================================
test_scenario2() {
    log_test "=== Scenario 2: invalid expression is reported, not applied ==="
    kubectl delete ec2nodeclass "$INVALID_NODECLASS" --ignore-not-found=true 2>/dev/null || true

    # "vcpu" (no s) is not a known variable, so the expression fails to type-check.
    # The API server accepts it; Karpenter reports it on the status instead.
    kubectl apply -f - <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: $INVALID_NODECLASS
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: "$KARPENTER_NODE_IAM_ROLE_NAME"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: $CLUSTER_NAME
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: $CLUSTER_NAME
  kubelet:
    maxPods: "vcpu * 8"
EOF

    local elapsed=0 reason=""
    while [ $elapsed -lt $TIMEOUT_NODECLASS_READY ]; do
        reason=$(nodeclass_condition "$INVALID_NODECLASS" ValidationSucceeded reason)
        [ -n "$reason" ] && [ "$(nodeclass_condition "$INVALID_NODECLASS" ValidationSucceeded status)" == "False" ] && break
        sleep 5
        elapsed=$((elapsed + 5))
    done

    local failed=0
    if [ "$reason" == "KubeletExpressionInvalid" ]; then
        log_test "✅ PASSED: ValidationSucceeded=False with reason KubeletExpressionInvalid"
    else
        log_error "❌ FAILED: expected reason KubeletExpressionInvalid, got '${reason}'"
        failed=1
    fi

    if [ "$(nodeclass_condition "$INVALID_NODECLASS" Ready status)" != "True" ]; then
        log_test "✅ PASSED: EC2NodeClass is not Ready, so no nodes launch from it"
    else
        log_error "❌ FAILED: EC2NodeClass with an invalid expression is Ready"
        failed=1
    fi

    kubectl delete ec2nodeclass "$INVALID_NODECLASS" --ignore-not-found=true 2>/dev/null || true

    if [ $failed -eq 0 ]; then
        log_test "✅ Scenario 2 PASSED"
    else
        log_error "❌ Scenario 2 FAILED"
    fi
    return $failed
}

main() {
    local scenario=${1:-all}
    check_prerequisites

    local failed=0
    case "$scenario" in
        scenario1) test_scenario1 || failed=1 ;;
        scenario2) test_scenario2 || failed=1 ;;
        all)
            test_scenario2 || failed=1
            test_scenario1 || failed=1
            ;;
        *)
            log_error "Unknown scenario: $scenario (use scenario1, scenario2 or all)"
            exit 1
            ;;
    esac

    cleanup
    rm -f "$RENDERED"

    if [ $failed -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
        exit 1
    fi
}

main "$@"
