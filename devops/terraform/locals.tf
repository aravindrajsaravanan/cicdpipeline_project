locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = "${var.project}-eks"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
  }

  # Console viewers: the account root user by default, plus any extra ARNs
  console_viewer_arns = concat(
    var.console_viewer_include_root ? ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"] : [],
    var.console_viewer_arns,
  )

  # First two AZs in the region
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}
