output "jenkins_url" {
  description = "Jenkins UI."
  value       = "http://${aws_instance.jenkins.public_ip}:8080"
}

output "sonarqube_url" {
  description = "SonarQube UI."
  value       = "http://${aws_instance.jenkins.public_ip}:9000"
}

output "jenkins_instance_id" {
  description = "Jenkins EC2 instance ID (for SSM Session Manager)."
  value       = aws_instance.jenkins.id
}

output "ecr_repository_url" {
  description = "ECR repository for the app image."
  value       = aws_ecr_repository.app.repository_url
}

output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.main.name
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.region} --profile ${var.aws_profile}"
}
