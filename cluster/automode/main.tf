provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "eks-auto-mode-blueprints"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    blueprint = local.name
  }
}

################################################################################
# Auto Mode Node IAM Role + Access Entry
#
# When cluster_compute_config.enabled = true, EKS Auto Mode launches managed
# nodes that need an IAM role with AmazonEKSAutoNodePolicy attached and an
# Access Entry of type EC2. The terraform-aws-modules/eks module creates the
# role implicitly; we make it explicit here so that every blueprint in this
# repo can reference cluster/automode/ as the canonical example.
################################################################################

resource "aws_iam_role" "auto_mode_node" {
  name = "${local.name}-auto-mode-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "auto_mode_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])

  role       = aws_iam_role.auto_mode_node.name
  policy_arn = each.value
}

################################################################################
# EKS Auto Mode Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.31.0"

  cluster_name                             = local.name
  cluster_version                          = "1.34"
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # Enable EKS Auto Mode with our explicit node IAM role
  cluster_compute_config = {
    enabled       = true
    node_pools    = ["general-purpose"]
    node_role_arn = aws_iam_role.auto_mode_node.arn
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # No managed node groups needed - Auto Mode handles compute
  eks_managed_node_groups = {}

  tags = local.tags
}

resource "aws_eks_access_entry" "auto_mode_node" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.auto_mode_node.arn
  type          = "EC2"
}

resource "aws_eks_access_policy_association" "auto_mode_node" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.auto_mode_node.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy"

  access_scope {
    type = "cluster"
  }
}

#---------------------------------------------------------------
# Supporting Resources
#---------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/internal-elb"     = 1
  }

  tags = local.tags
}
