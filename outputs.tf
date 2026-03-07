output "ecr_repository_name" {
  description = "Name of the ECR repository."
  value       = aws_ecr_repository.app.name
}

output "ecr_repository_url" {
  description = "Repository URL for pushing container images."
  value       = aws_ecr_repository.app.repository_url
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "subnet_ids" {
  description = "IDs of the created subnets."
  value       = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
}

output "eks_cluster_name" {
  description = "EKS cluster name when enable_eks = true."
  value       = try(aws_eks_cluster.main[0].name, null)
}

output "eks_node_group_name" {
  description = "EKS node group name when enable_eks = true."
  value       = try(aws_eks_node_group.main[0].node_group_name, null)
}
