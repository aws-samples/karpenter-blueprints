locals {
  karpenter_namespace = "karpenter"
}

################################################################################
# Controller & Node IAM roles, SQS Queue, Eventbridge Rules
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.10.1"

  cluster_name = module.eks.cluster_name
  namespace    = local.karpenter_namespace

  # Name needs to match role name passed to the EC2NodeClass
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = local.name
  create_pod_identity_association = true

  tags = local.tags
}

################################################################################
# Helm charts
################################################################################

resource "helm_release" "karpenter" {
  name                = "karpenter"
  namespace           = local.karpenter_namespace
  create_namespace    = true
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.8.3"
  wait                = false

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
    webhook:
      enabled: false
    EOT
  ]

  lifecycle {
    ignore_changes = [
      repository_password
    ]
  }
}

# Karpenter default EC2NodeClass and NodePool

resource "kubectl_manifest" "karpenter_default_ec2_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      role: "${module.karpenter.node_iam_role_name}"
      amiSelectorTerms:
      - alias: al2023@latest
      securityGroupSelectorTerms:
      - tags:
          karpenter.sh/discovery: ${module.eks.cluster_name}
      subnetSelectorTerms:
      - tags:
          karpenter.sh/discovery: ${module.eks.cluster_name}
      tags:
        IntentLabel: apps
        KarpenterNodePoolName: default
        NodeType: default
        intent: apps
        karpenter.sh/discovery: ${module.eks.cluster_name}
        project: karpenter-blueprints
  YAML

  depends_on = [
    helm_release.karpenter,
  ]
}

resource "kubectl_manifest" "karpenter_default_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        metadata:
          labels:
            intent: apps
        spec:
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64", "arm64"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: In
              values: ["4", "8", "16", "32", "48", "64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c", "m", "r", "i", "d"]
          nodeClassRef:
            name: default
            group: karpenter.k8s.aws
            kind: EC2NodeClass
          kubelet:
            containerRuntime: containerd
            systemReserved:
              cpu: 100m
              memory: 100Mi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [
    helm_release.karpenter,
    kubectl_manifest.karpenter_default_ec2_node_class,
  ]
}
