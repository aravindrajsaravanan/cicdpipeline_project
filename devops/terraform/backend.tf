# State bucket is created once, outside Terraform (see README "Bootstrap").
# use_lockfile = S3-native state locking (no DynamoDB table needed).
terraform {
  backend "s3" {
    bucket       = "cicd-tfstate-718460151470"
    key          = "cicdpipeline/terraform.tfstate"
    region       = "ap-south-1"
    profile      = "cicd"
    encrypt      = true
    use_lockfile = true
  }
}
