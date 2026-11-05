locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = "${var.project}-eks"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
  }

  # First two AZs in the region
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}
