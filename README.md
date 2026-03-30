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
5. `SYNC_PUBLIC_K8S_ROUTES`: `false` or `true`
6. `K8S_NAMESPACE`: target namespace for the application Deployment
7. `K8S_DEPLOYMENT`: target Deployment name for mail environment injection
8. `K8S_REMOTE_HOST`: Azure VM public IP or public DNS reachable from Jenkins
9. `K8S_REMOTE_PORT`: SSH port for that Azure VM
10. `K8S_REMOTE_CONTAINER`: optional k3d server container name; leave blank to auto-detect
11. `PUBLIC_GATEWAY_SERVER_NAME`: nginx `server_name` for the public site
12. `PUBLIC_GATEWAY_SITE_CONFIG`: optional exact nginx site config path; leave blank to auto-detect

If `abort` is selected, the pipeline exits before infrastructure changes.
If `SYNC_K8S_MAIL_ENV=true`, Jenkins connects to the Azure VM over SSH, runs `docker exec ... kubectl ...` against the k3d server container, creates or updates a Kubernetes `Secret` and `ConfigMap` from Jenkins credentials, and patches the target Deployment so pods can consume the mail settings.
If `SYNC_PUBLIC_K8S_ROUTES=true`, Jenkins connects to the same Azure VM over SSH, writes an nginx include with the branded app routes from `config/public-k8s-routes.txt`, ensures the public site includes that file, tests nginx, and reloads it.

## Repository layout

- `Jenkinsfile`: runtime selector + conditional execution
- `scripts/k8s_mail_env.sh`: Kubernetes mail Secret/ConfigMap sync helper
- `scripts/public_k8s_gateway_routes.sh`: public nginx route sync helper for branded app paths
- `scripts/localstack_infra.sh`: AWS CLI workflow
- `scripts/terraform_infra.sh`: Terraform workflow wrapper
- `config/k8s.env.example`: optional defaults for Kubernetes mail sync
- `config/public-gateway.env.example`: optional defaults for public nginx route sync
- `config/public-k8s-routes.txt`: branded public path prefixes that should proxy to k3d ingress
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

Required when `SYNC_K8S_MAIL_ENV=true` or `SYNC_PUBLIC_K8S_ROUTES=true`:

- `VM_SSH_KEY` (`SSH Username with private key`)

Required only when `SYNC_K8S_MAIL_ENV=true`:

- `MAIL_HOST`
- `MAIL_PORT`
- `MAIL_USERNAME`
- `MAIL_PASSWORD`
- `APP_CONTACT_MAIL_FROM`

Important:

- `TF_VAR_SSH_PUBLIC_KEY` is the public key Terraform places on the VM. It is not the credential Jenkins uses to SSH into the VM.
- Jenkins must use the private key credential in `VM_SSH_KEY` for the remote Kubernetes sync.
- Jenkins must use the same `VM_SSH_KEY` credential for the public nginx route sync.
- `K8S_REMOTE_HOST` must be the public IP or public DNS that Jenkins can resolve, for example `68.155.156.136`.
- Do not use the Azure VM resource name or a local SSH alias from your laptop unless Jenkins can resolve that same host name.

## Kubernetes mail sync

When enabled, Jenkins runs `scripts/k8s_mail_env.sh` after the infrastructure stage. The script:

- creates or updates `mail-secret` with `MAIL_USERNAME` and `MAIL_PASSWORD`
- creates or updates `mail-config` with `MAIL_HOST`, `MAIL_PORT`, and `APP_CONTACT_MAIL_FROM`
- connects to the Azure VM over SSH
- auto-detects the first `k3d-*-server-0` container when `K8S_REMOTE_CONTAINER` is blank
- executes `kubectl` inside that Docker container
- patches the target Deployment with those environment variables
- restarts the Deployment so new pods read the refreshed values

Prerequisites:

- the Jenkins agent must have an `ssh` client installed
- Jenkins must have a `VM_SSH_KEY` credential that can connect to the Azure VM
- the Azure VM must have Docker access to the k3d cluster container
- the target Deployment must already exist in the selected namespace

Current known workload values:

- `K8S_NAMESPACE=hello-spring`
- `K8S_DEPLOYMENT=hello-spring`
- `K8S_REMOTE_HOST=68.155.156.136` unless you configure a resolvable DNS name for Jenkins

## Public gateway route sync

When enabled, Jenkins runs `scripts/public_k8s_gateway_routes.sh` after the infrastructure stage. The script:

- reads the branded public paths from `config/public-k8s-routes.txt`
- keeps `/` on the static nginx hub page
- writes an nginx include file with `location` blocks only for those branded paths
- proxies those paths to `http://127.0.0.1:8081`, which is the k3d ingress listener published by LocalStack
- auto-detects the nginx site config for `nauthappstest.tech` unless you provide `PUBLIC_GATEWAY_SITE_CONFIG`
- adds `include /etc/nginx/nauthapps.d/*.conf;` to the matching `server_name` block when missing, preferring the TLS/443 block when the file contains both HTTP and HTTPS server blocks
- runs `nginx -t` and reloads nginx

Why this matters:

- the public VM nginx is the first gate
- Kubernetes ingress inside k3d is the second gate
- both gates must know about `/Whisper` and its aliases
- this keeps `https://nauthappstest.tech/` on the welcome page, while `https://nauthappstest.tech/Whisper` goes to the Spring Boot app

Prerequisites:

- the Jenkins agent must have an `ssh` client installed
- Jenkins must have the `VM_SSH_KEY` credential
- the Azure VM user must be able to run `sudo nginx -t` and reload nginx
- the nginx site file for `PUBLIC_GATEWAY_SERVER_NAME` can be a single-site file or a combined HTTP+HTTPS file; if several identical matching blocks exist, set `PUBLIC_GATEWAY_SITE_CONFIG` to a more specific file or add the include manually

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
export K8S_ACCESS_MODE=ssh-docker
export K8S_NAMESPACE=hello-spring
export K8S_DEPLOYMENT=hello-spring
export K8S_REMOTE_HOST=68.155.156.136
export K8S_REMOTE_PORT=22
export K8S_REMOTE_USER=azureuser
# Leave blank to auto-detect the first k3d server-0 container.
export K8S_REMOTE_CONTAINER=
export SSH_KEY_FILE=~/.ssh/azure-vm
export MAIL_HOST=smtp.gmail.com
export MAIL_PORT=587
export MAIL_USERNAME=your-account@gmail.com
export MAIL_PASSWORD=<gmail-app-password>
export APP_CONTACT_MAIL_FROM=your-account@gmail.com

bash scripts/k8s_mail_env.sh apply
```

Public gateway route sync only:

```bash
export PUBLIC_GATEWAY_ACCESS_MODE=ssh
export PUBLIC_GATEWAY_REMOTE_HOST=68.155.156.136
export PUBLIC_GATEWAY_REMOTE_PORT=22
export PUBLIC_GATEWAY_REMOTE_USER=azureuser
export SSH_KEY_FILE=~/.ssh/azure-vm
export PUBLIC_GATEWAY_SERVER_NAME=nauthappstest.tech
# Leave blank to auto-detect the nginx site config file.
export PUBLIC_GATEWAY_SITE_CONFIG=

bash scripts/public_k8s_gateway_routes.sh apply
```

## Notes

- `ENABLE_EKS=false` is still the safest default while validating baseline flows.
- `artifacts/outputs.env` now includes `DEPLOYMENT_MODE=terraform|awscli`.
- `artifacts/k8s-mail-sync.txt` is generated when Kubernetes mail sync runs.
- `artifacts/public-gateway-routes.txt` is generated when public nginx route sync runs.
