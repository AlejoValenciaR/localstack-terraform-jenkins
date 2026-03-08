variable "aws_region" {
  description = "AWS region used by LocalStack."
  type        = string
  default     = "us-east-1"
}

variable "localstack_endpoint_url" {
  description = "Base URL for your LocalStack instance."
  type        = string
  default     = "https://localstack.nauthappstest.tech"
}

variable "aws_access_key" {
  description = "Access key used for LocalStack authentication. With ENFORCE_IAM=1 this must belong to an authorized IAM principal."
  type        = string
  default     = "test"
  sensitive   = true
}

variable "aws_secret_key" {
  description = "Secret key used for LocalStack authentication. With ENFORCE_IAM=1 this must belong to an authorized IAM principal."
  type        = string
  default     = "test"
  sensitive   = true
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository."
  type        = string
  default     = "hello-spring"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_1_cidr" {
  description = "CIDR block for subnet A."
  type        = string
  default     = "10.0.1.0/24"
}

variable "subnet_2_cidr" {
  description = "CIDR block for subnet B."
  type        = string
  default     = "10.0.2.0/24"
}

variable "enable_eks" {
  description = "Set to true to create EKS resources (often limited in LocalStack)."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "localstack-eks-cluster"
}

variable "eks_node_group_name" {
  description = "EKS node group name."
  type        = string
  default     = "localstack-eks-node-group"
}

variable "eks_node_instance_types" {
  description = "Node instance types for EKS node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 1
}

variable "eks_node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 2
}
