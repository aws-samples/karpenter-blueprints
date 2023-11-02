# Scoped permission to add to Karpenter role

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.id
  node_iam_role_name = module.eks_blueprints_addons.karpenter.node_iam_role_name
  iam_role_name = module.eks_blueprints_addons.karpenter.iam_role_name
}
data "aws_iam_policy_document" "karpenter_policy" {
  version = "2012-10-17"

  statement {
    sid    = "AllowScopedEC2InstanceActions"
    effect = "Allow"

    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet"
    ]

    resources = [
      "arn:${local.partition}:ec2:${var.region}::image/*",
      "arn:${local.partition}:ec2:${var.region}::snapshot/*",
      "arn:${local.partition}:ec2:${var.region}:*:spot-instances-request/*",
      "arn:${local.partition}:ec2:${var.region}:*:security-group/*",
      "arn:${local.partition}:ec2:${var.region}:*:subnet/*",
      "arn:${local.partition}:ec2:${var.region}:*:launch-template/*"
    ]
  }

  statement {
    sid    = "AllowScopedEC2InstanceActionsWithTags"
    effect = "Allow"

    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate"
    ]

    resources = [
      "arn:${local.partition}:ec2:${var.region}:*:fleet/*",
      "arn:${local.partition}:ec2:${var.region}:*:instance/*",
      "arn:${local.partition}:ec2:${var.region}:*:volume/*",
      "arn:${local.partition}:ec2:${var.region}:*:network-interface/*",
      "arn:${local.partition}:ec2:${var.region}:*:launch-template/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${local.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowScopedResourceCreationTagging"
    effect = "Allow"

    actions   = ["ec2:CreateTags"]
    resources = [
      "arn:${local.partition}:ec2:${var.region}:*:fleet/*",
      "arn:${local.partition}:ec2:${var.region}:*:instance/*",
      "arn:${local.partition}:ec2:${var.region}:*:volume/*",
      "arn:${local.partition}:ec2:${var.region}:*:network-interface/*",
      "arn:${local.partition}:ec2:${var.region}:*:launch-template/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${local.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowScopedResourceTagging"
    effect = "Allow"

    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:${var.region}:*:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }

    condition {
      test = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values = [
        "karpenter.sh/nodeclaim",
        "Name"
      ]
    }
  }

  statement {
    sid    = "AllowScopedDeletion"
    effect = "Allow"

    actions = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]

    resources = [
      "arn:${local.partition}:ec2:${var.region}:*:instance/*",
      "arn:${local.partition}:ec2:${var.region}:*:launch-template/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowRegionalReadActions"
    effect = "Allow"

    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid    = "AllowSSMReadActions"
    effect = "Allow"

    actions = ["ssm:GetParameter"]

    resources = ["arn:${local.partition}:ssm:${var.region}::parameter/aws/service/*"]
  }

  statement {
    sid    = "AllowPricingReadActions"
    effect = "Allow"

    actions = ["pricing:GetProducts"]

    resources = ["*"]
  }

  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"

    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage"
    ]

    resources = ["${module.eks_blueprints_addons.karpenter.sqs.queue_arn}"]
  }

  statement {
    sid    = "AllowPassingInstanceRole"
    effect = "Allow"

    actions = ["iam:PassRole"]

    resources = ["arn:${local.partition}:iam::${local.account_id}:role/KarpenterNodeRole-${local.name}"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid    = "AllowScopedInstanceProfileCreationActions"
    effect = "Allow"

    actions = ["iam:CreateInstanceProfile"]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${local.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [var.region]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowScopedInstanceProfileTagActions"
    effect = "Allow"

    actions = ["iam:TagInstanceProfile"]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [var.region]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${local.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [var.region]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid     = "AllowScopedInstanceProfileActions"
    effect = "Allow"

    actions = [
        "iam:AddRoleToInstanceProfile", 
    "iam:RemoveRoleFromInstanceProfile", 
    "iam:DeleteInstanceProfile"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [var.region]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowInstanceProfileReadActions"
    effect = "Allow"

    actions = ["iam:GetInstanceProfile"]

    resources = ["*"]
  }

  statement {
    sid    = "AllowAPIServerEndpointDiscovery"
    effect = "Allow"

    actions = ["eks:DescribeCluster"]

    resources = ["arn:${local.partition}:eks:${var.region}:${local.account_id}:cluster/${local.name}"]
  }
}

resource "aws_iam_policy" "karpenter_policy" {
  name   = "KarpenterNodeRole-${local.name}"
  policy = data.aws_iam_policy_document.karpenter_policy.json
}

resource "aws_iam_role_policy_attachment" "karpenter_policy" {
  role       = local.iam_role_name
  policy_arn = aws_iam_policy.karpenter_policy.arn
}
