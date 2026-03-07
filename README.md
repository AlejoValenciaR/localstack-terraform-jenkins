# Terraform + Jenkins + LocalStack (Beginner Friendly)

This project lets Jenkins run Terraform against your LocalStack endpoint:

- LocalStack URL: `https://localstack.nauthappstest.tech`
- AWS region: `us-east-1`
- Flow: `VS Code git push -> GitHub webhook -> Jenkins pipeline -> terraform plan/apply/destroy`

## What This Project Creates

- `aws_ecr_repository` (default name: `hello-spring`)
- `aws_vpc` (`10.0.0.0/16`)
- Two subnets:
  - `10.0.1.0/24`
  - `10.0.2.0/24`
- Optional EKS resources (disabled by default):
  - IAM role for EKS cluster + policy attachments
  - IAM role for EKS nodegroup + policy attachments
  - EKS cluster + node group when `enable_eks = true`

## Files

- `versions.tf` Terraform + provider versions
- `backend.tf` AzureRM backend block
- `providers.tf` AWS provider configured for LocalStack endpoint
- `variables.tf` Input variables and defaults
- `main.tf` AWS resources
- `outputs.tf` Useful output values
- `Jenkinsfile` CI pipeline
- `.gitignore` Terraform/Jenkins local artifacts

## Prerequisites

1. Jenkins has an agent with these tools installed:
   - Terraform (`>= 1.6`)
   - Git
   - AWS CLI (for optional connectivity checks)
2. You already have an Azure Storage backend ready for Terraform state:
   - Resource Group name
   - Storage Account name
   - Blob container name
3. LocalStack is reachable from Jenkins at:
   - `https://localstack.nauthappstest.tech`

## 1) Verify LocalStack Connectivity

Run these checks from your machine or Jenkins agent:

```bash
curl https://localstack.nauthappstest.tech/_localstack/health
```

```bash
aws --endpoint-url https://localstack.nauthappstest.tech sts get-caller-identity --region us-east-1
```

If needed, set credentials first:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
```

## 2) Push This Project to GitHub

1. Initialize git (if needed) and push this folder to your GitHub repository.
2. Make sure your Jenkins job points to this repository.

## 3) Configure Jenkins Credentials

Create these credentials in Jenkins (`Manage Jenkins -> Credentials`) as **Secret text**:

- `LS_AWS_ACCESS_KEY_ID`
- `LS_AWS_SECRET_ACCESS_KEY`
- `LS_ENDPOINT_URL` (set value to `https://localstack.nauthappstest.tech`)
- `ARM_CLIENT_ID`
- `ARM_CLIENT_SECRET`
- `ARM_TENANT_ID`
- `ARM_SUBSCRIPTION_ID`
- `TFSTATE_RESOURCE_GROUP`

## 4) Create Jenkins Pipeline Job

1. Create a new Pipeline job.
2. Configure SCM to your GitHub repo and branch.
3. Set pipeline script source to `Jenkinsfile`.
4. Save.

State backend values are now fixed in `Jenkinsfile` environment variables:

- `TFSTATE_STORAGE_ACCOUNT=alejatfstate2026demo`
- `TFSTATE_CONTAINER=tfstate`
- `TFSTATE_KEY=localstack-terraform-jenkins.tfstate`

## 5) Configure GitHub Webhook

In GitHub repo settings:

- Payload URL: `<jenkins-url>/github-webhook/`
- Content type: `application/json`
- Event: `Just the push event`

This triggers Jenkins on every push. After `terraform validate`, Jenkins pauses and asks you which path to take: `apply`, `destroy`, or `abort`.

## 6) Pipeline Behavior

Pipeline stages:

1. `checkout`
2. `terraform init` (Azure backend style via `-backend-config`)
3. `fmt/validate`
4. `choose action`
5. `plan`
6. `apply/destroy`

How the runtime action works:

- `apply`: Jenkins creates a normal plan and then applies it
- `destroy`: Jenkins creates a destroy plan and then applies it
- `abort`: Jenkins stops the build without changing infrastructure

## 7) Optional EKS

EKS resources are disabled by default:

```hcl
enable_eks = false
```

To enable:

```bash
terraform plan -var="enable_eks=true"
```

## Known Caveats (EKS + LocalStack)

- EC2/VPC support in LocalStack can differ from real AWS. This project keeps the VPC resource minimal because DNS attribute updates such as `enable_dns_support` and `enable_dns_hostnames` may hang or fail in some LocalStack environments.
- EKS support in LocalStack can be partial depending on version/edition.
- EKS or nodegroup creation may fail or behave differently from real AWS.
- Keep `enable_eks = false` for stable beginner runs unless you know your LocalStack instance supports EKS fully.
- Use this setup for development/testing, not production infrastructure.
