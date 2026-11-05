variable "project" {
  description = "Project name, used as a prefix for every resource. IAM permissions only allow roles named cicd-*."
  type        = string
  default     = "cicd"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
  default     = "aravindrajsaravanan"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use."
  type        = string
  default     = "cicd"
}

variable "admin_cidr" {
  description = "Your public IP in CIDR form (x.x.x.x/32). Only this address can reach Jenkins, SonarQube and the EKS API."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && endswith(var.admin_cidr, "/32")
    error_message = "admin_cidr must be a single IP in CIDR form, e.g. 203.0.113.10/32."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.37"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes."
  type        = string
  default     = "t3.large"
}

variable "node_count" {
  description = "Number of EKS worker nodes (min = max = desired)."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 5
    error_message = "node_count must be between 1 and 5."
  }
}

variable "node_disk_size_gb" {
  description = "Root disk size for each EKS node, in GB."
  type        = number
  default     = 30
}

variable "jenkins_instance_type" {
  description = "EC2 instance type for the Jenkins + SonarQube server (SonarQube needs ~4 GB RAM)."
  type        = string
  default     = "t3.large"
}

variable "jenkins_disk_size_gb" {
  description = "Root disk size for the Jenkins server, in GB."
  type        = number
  default     = 30
}
