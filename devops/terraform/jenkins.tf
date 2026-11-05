# Jenkins + SonarQube server. No SSH: access is through SSM Session Manager.

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# ---------- IAM role (instance profile) ----------
resource "aws_iam_role" "jenkins" {
  name               = "${var.project}-jenkins-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "jenkins_ecr_push" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushToAppRepoOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "jenkins_ecr_push" {
  name   = "ecr-push-app-repo"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_ecr_push.json
}

# Parameter Store: read the GitHub token, read/write the generated admin passwords. /cicd/* only.
data "aws_iam_policy_document" "jenkins_params" {
  statement {
    sid       = "ReadProjectParams"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/*"]
  }

  statement {
    sid     = "WriteGeneratedPasswords"
    actions = ["ssm:PutParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/jenkins-admin-password",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/sonarqube-admin-password",
    ]
  }
}

resource "aws_iam_role_policy" "jenkins_params" {
  name   = "parameter-store-cicd"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_params.json
}

data "aws_caller_identity" "current" {}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}

# ---------- Security group ----------
resource "aws_security_group" "jenkins" {
  name        = "${local.name}-jenkins-sg"
  description = "Jenkins and SonarQube - reachable only from the admin IP"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-jenkins-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_ui" {
  security_group_id = aws_security_group.jenkins.id
  description       = "Jenkins UI"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

resource "aws_vpc_security_group_ingress_rule" "sonarqube_ui" {
  security_group_id = aws_security_group.jenkins.id
  description       = "SonarQube UI"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 9000
  to_port           = 9000
}

resource "aws_vpc_security_group_egress_rule" "jenkins_all_out" {
  security_group_id = aws_security_group.jenkins.id
  description       = "Outbound to GitHub, ECR, package mirrors"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- Instance ----------
resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.jenkins_instance_type
  subnet_id              = aws_subnet.public[local.azs[0]].id
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  # JCasC file is injected base64-encoded so the script stays a plain bash file
  user_data = replace(
    file("${path.module}/../scripts/jenkins-setup.sh"),
    "__CASC_B64__",
    base64encode(file("${path.module}/../jenkins/casc.yaml"))
  )
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.jenkins_disk_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${local.name}-jenkins" }

  lifecycle {
    ignore_changes = [ami] # don't rebuild Jenkins every time Ubuntu publishes a new AMI
  }

  # The setup script reads Parameter Store at boot, so the permission must exist first
  depends_on = [aws_iam_role_policy.jenkins_params]
}
