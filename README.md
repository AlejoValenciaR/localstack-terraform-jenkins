# Jenkins + LocalStack: Terraform or AWS CLI

This repository supports two deployment engines, selected at runtime in Jenkins:

- `terraform`: Terraform files (`main.tf`, `variables.tf`, etc.) plus `scripts/terraform_infra.sh`
- `awscli`: Ordered AWS CLI workflow in `scripts/localstack_infra.sh`

Both engines support:

- `apply`
- `destroy`
- `status`
- `abort` (pipeline stop from the Jenkins input step)

## Jenkins runtime choice

The pipeline now asks for:

1. `INFRA_DEPLOYMENT`: `terraform` or `awscli`
2. `INFRA_ACTION`: `apply`, `destroy`, `status`, `abort`
3. `ENABLE_EKS`: `false` or `true`

If `abort` is selected, the pipeline exits before infrastructure changes.

## Repository layout

- `Jenkinsfile`: runtime selector + conditional execution
- `scripts/localstack_infra.sh`: AWS CLI workflow
- `scripts/terraform_infra.sh`: Terraform workflow wrapper
- `main.tf`, `variables.tf`, `providers.tf`, `outputs.tf`, `versions.tf`, `backend.tf`: Terraform IaC
- `config/infra.env.example`: optional defaults for AWS CLI workflow
- `config/terraform.env.example`: optional defaults for Terraform workflow
- `artifacts/`: generated at runtime (`outputs.env`, terraform output/state files, health files)

## Jenkins credentials

Always required (both modes):

- `LS_AWS_ACCESS_KEY_ID`
- `LS_AWS_SECRET_ACCESS_KEY`
- `LS_ENDPOINT_URL`

Required only for `terraform` mode with remote AzureRM backend:

- `ARM_CLIENT_ID`
- `ARM_CLIENT_SECRET`
- `ARM_TENANT_ID`
- `ARM_SUBSCRIPTION_ID`
- `TFSTATE_RESOURCE_GROUP`

## Terraform backend defaults

Jenkinsfile sets:

- `TFSTATE_STORAGE_ACCOUNT=alejatfstate2026demo`
- `TFSTATE_CONTAINER=tfstate`
- `TFSTATE_KEY=localstack-terraform-jenkins.tfstate`

You can override these with environment variables if needed.

## Local run examples

AWS CLI mode:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_REGION=us-east-1
export LS_ENDPOINT_URL=https://localstack.nauthappstest.tech

bash scripts/localstack_infra.sh apply
bash scripts/localstack_infra.sh status
```

Terraform mode (local backend for quick tests):

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_REGION=us-east-1
export LS_ENDPOINT_URL=https://localstack.nauthappstest.tech
export TF_DISABLE_BACKEND=true

bash scripts/terraform_infra.sh apply
bash scripts/terraform_infra.sh status
```

## Notes

- `ENABLE_EKS=false` is still the safest default while validating baseline flows.
- `artifacts/outputs.env` now includes `DEPLOYMENT_MODE=terraform|awscli`.
