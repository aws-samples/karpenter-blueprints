# Karpenter default AwsNodeTemplate and Provisioner

resource "kubectl_manifest" "karpenter_default_awsnodetemplate" {
  yaml_body = <<YAML
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
metadata:
  name: default
spec:
  subnetSelector:
    karpenter.sh/discovery: ${local.name}
  securityGroupSelector:
    karpenter.sh/discovery: ${local.name}
  instanceProfile: "${module.eks_blueprints_addons.karpenter.node_instance_profile_name}"
  tags:
    karpenter.sh/discovery: ${local.name}
    intent: apps
    project: karpenter-blueprints
    KarpenterProvisionerName: "default"
    NodeType: "default"
    IntentLabel: "apps"
YAML
  depends_on = [
    module.eks.cluster,
    module.eks_blueprints_addons.karpenter,
  ]
}

resource "kubectl_manifest" "karpenter_default_provisioner" {
  yaml_body = <<YAML
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  labels:
    intent: apps
  requirements:
    - key: "karpenter.k8s.aws/instance-category"
      operator: In
      values: ["c", "m", "r", "i", "d"]
    - key: "karpenter.k8s.aws/instance-cpu"
      operator: In
      values: ["4", "8", "16", "32", "48", "64"]
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["spot", "on-demand"]
    - key: kubernetes.io/arch
      operator: In
      values: ["amd64", "arm64"]
  kubeletConfiguration:
    containerRuntime: containerd
  limits:
    resources:
      cpu: 100000
      memory: 5000Gi
  consolidation:
    enabled: true
  ttlSecondsUntilExpired: 604800
  providerRef:
    name: default
YAML
  depends_on = [
    module.eks.cluster,
    module.eks_blueprints_addons.karpenter,
    kubectl_manifest.karpenter_default_awsnodetemplate,
  ]
}
