# ---------- Cluster role ----------
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.project}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------- Cluster ----------
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true # claude_user gets cluster admin
  }

  vpc_config {
    subnet_ids              = [for s in aws_subnet.public : s.id]
    endpoint_public_access  = true
    endpoint_private_access = true # nodes talk to the API privately
    public_access_cidrs     = [var.admin_cidr]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

# ---------- Node role ----------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.project}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

# ---------- Managed node group ----------
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = [for s in aws_subnet.public : s.id]

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = [var.node_instance_type]
  disk_size      = var.node_disk_size_gb

  scaling_config {
    min_size     = var.node_count
    max_size     = var.node_count
    desired_size = var.node_count
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.eks_node]
}
