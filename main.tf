resource "aws_ecr_repository" "app" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }
}

resource "aws_vpc" "main" {
  # LocalStack EC2 can fail when Terraform tries to mutate VPC DNS attributes
  # immediately after creation, so keep the VPC definition minimal here.
  cidr_block = var.vpc_cidr

  tags = {
    Name = "localstack-main-vpc"
  }
}

resource "aws_subnet" "subnet_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_1_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "localstack-subnet-a"
  }
}

resource "aws_subnet" "subnet_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_2_cidr
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = {
    Name = "localstack-subnet-b"
  }
}

data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "eks_cluster_permissions" {
  statement {
    actions = [
      "ec2:*",
      "eks:*",
      "iam:PassRole",
      "sts:AssumeRole",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "eks_cluster" {
  count = var.enable_eks ? 1 : 0

  name               = "${var.eks_cluster_name}-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume_role.json
}

resource "aws_iam_policy" "eks_cluster" {
  count = var.enable_eks ? 1 : 0

  name   = "${var.eks_cluster_name}-policy"
  policy = data.aws_iam_policy_document.eks_cluster_permissions.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  count = var.enable_eks ? 1 : 0

  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = aws_iam_policy.eks_cluster[0].arn
}

data "aws_iam_policy_document" "eks_node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "eks_node_permissions" {
  statement {
    actions = [
      "ec2:*",
      "ecr:*",
      "eks:*",
      "sts:AssumeRole",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "eks_node" {
  count = var.enable_eks ? 1 : 0

  name               = "${var.eks_node_group_name}-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume_role.json
}

resource "aws_iam_policy" "eks_node" {
  count = var.enable_eks ? 1 : 0

  name   = "${var.eks_node_group_name}-policy"
  policy = data.aws_iam_policy_document.eks_node_permissions.json
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  count = var.enable_eks ? 1 : 0

  role       = aws_iam_role.eks_node[0].name
  policy_arn = aws_iam_policy.eks_node[0].arn
}

resource "aws_eks_cluster" "main" {
  count = var.enable_eks ? 1 : 0

  name     = var.eks_cluster_name
  role_arn = aws_iam_role.eks_cluster[0].arn

  vpc_config {
    subnet_ids = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

resource "aws_eks_node_group" "main" {
  count = var.enable_eks ? 1 : 0

  cluster_name    = aws_eks_cluster.main[0].name
  node_group_name = var.eks_node_group_name
  node_role_arn   = aws_iam_role.eks_node[0].arn
  subnet_ids      = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
  instance_types  = var.eks_node_instance_types

  scaling_config {
    desired_size = var.eks_node_desired_size
    min_size     = var.eks_node_min_size
    max_size     = var.eks_node_max_size
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node,
    aws_eks_cluster.main,
  ]
}
