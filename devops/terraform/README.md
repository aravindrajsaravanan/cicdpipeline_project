# Terraform: cicd infrastructure (ap-south-1)

| File | Creates |
|---|---|
| `network.tf` | VPC `10.20.0.0/16`, 2 public subnets (2 AZs), internet gateway. No NAT (learning setup). |
| `ecr.tf` | ECR repo `cicd-app` (immutable tags, scan on push, keep last 10 images) |
| `eks.tf` | EKS cluster `cicd-eks` + managed node group (2 x t3.large, 30 GB), IAM roles |
| `jenkins.tf` | Jenkins + SonarQube EC2 (t3.large, 30 GB, IMDSv2, SSM, no SSH), instance role with ECR push to `cicd-app` only |
| `../scripts/jenkins-setup.sh` | User-data: Java 21, Jenkins LTS, Docker, Trivy, AWS CLI, sonar-scanner, SonarQube + Postgres |

Jenkins (8080), SonarQube (9000) and the EKS API are reachable **only from `admin_cidr`**.

## Bootstrap (once)

State lives in S3 bucket `cicd-tfstate-718460151470` (versioned, encrypted, public access blocked, S3-native locking).

Create `cicd.auto.tfvars` (git-ignored) with your public IP:

```hcl
admin_cidr = "x.x.x.x/32"   # curl https://checkip.amazonaws.com
```

## Apply

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Your IP changed? Update `cicd.auto.tfvars`, then plan + apply again (only the security group and EKS CIDR change).

## Teardown (order matters)

The app's LoadBalancer is created by Kubernetes, not Terraform. Delete it first,
or it keeps billing and blocks the VPC from being deleted.

```bash
kubectl delete -n argocd application cicd-app   # finalizer removes the app + its load balancer
kubectl get svc -A | grep LoadBalancer           # should print nothing
terraform destroy
```

The state bucket is kept (a few cents per month). Delete it from the S3 console if you're done for good.

## Cost (approx.)

EKS $0.10/h + 3 x t3.large ~ $0.27/h + load balancer ~ $0.03/h  =  **~$0.40/hour**. Destroy when you stop.
