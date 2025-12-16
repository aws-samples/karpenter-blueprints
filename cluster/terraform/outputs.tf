output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "cluster_name" {
  description = "Cluster name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "VPC ID that the EKS cluster is using"
  value       = module.vpc.vpc_id
}

output "node_instance_role_name" {
  description = "IAM Role name that each Karpenter node will use"
  value       = local.name
}

output "region" {
  description = "AWS region where the cluster is deployed"
  value       = var.region
}

output "availability_zones" {
  description = "Availability zones used by the cluster"
  value       = local.azs
}
