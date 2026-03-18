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
4. `SYNC_K8S_MAIL_ENV`: `false` or `true`
5. `K8S_NAMESPACE`: target namespace for the application Deployment
6. `K8S_DEPLOYMENT`: target Deployment name for mail environment injection

If `abort` is selected, the pipeline exits before infrastructure changes.
If `SYNC_K8S_MAIL_ENV=true`, Jenkins also creates or updates a Kubernetes `Secret` and `ConfigMap` from Jenkins credentials and patches the target Deployment so pods can consume the mail settings.

## Repository layout

- `Jenkinsfile`: runtime selector + conditional execution
- `scripts/k8s_mail_env.sh`: Kubernetes mail Secret/ConfigMap sync helper
- `scripts/localstack_infra.sh`: AWS CLI workflow
- `scripts/terraform_infra.sh`: Terraform workflow wrapper
- `config/k8s.env.example`: optional defaults for Kubernetes mail sync
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

Required only when `SYNC_K8S_MAIL_ENV=true`:

- `MAIL_HOST`
- `MAIL_PORT`
- `MAIL_USERNAME`
- `MAIL_PASSWORD`
- `APP_CONTACT_MAIL_FROM`

## Kubernetes mail sync

When enabled, Jenkins runs `scripts/k8s_mail_env.sh` after the infrastructure stage. The script:

- creates or updates `mail-secret` with `MAIL_USERNAME` and `MAIL_PASSWORD`
- creates or updates `mail-config` with `MAIL_HOST`, `MAIL_PORT`, and `APP_CONTACT_MAIL_FROM`
- patches the target Deployment with those environment variables
- restarts the Deployment so new pods read the refreshed values

Prerequisites:

- the Jenkins agent must have `kubectl` installed
- the Jenkins agent must already have access to the target cluster context
- the target Deployment must already exist in the selected namespace

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

Kubernetes mail sync only:

```bash
export K8S_NAMESPACE=default
export K8S_DEPLOYMENT=my-app
export MAIL_HOST=smtp.gmail.com
export MAIL_PORT=587
export MAIL_USERNAME=your-account@gmail.com
export MAIL_PASSWORD=<gmail-app-password>
export APP_CONTACT_MAIL_FROM=your-account@gmail.com

bash scripts/k8s_mail_env.sh apply
```

## Notes

- `ENABLE_EKS=false` is still the safest default while validating baseline flows.
- `artifacts/outputs.env` now includes `DEPLOYMENT_MODE=terraform|awscli`.
- `artifacts/k8s-mail-sync.txt` is generated when Kubernetes mail sync runs.
