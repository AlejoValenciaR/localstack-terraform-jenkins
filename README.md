# Jenkins + AWS CLI + LocalStack (Terraform-Free)

This repository was refactored to remove Terraform and use ordered AWS CLI commands instead.

## Direct answer to your main question

Yes. If your LocalStack endpoint is reachable from Jenkins over the internet, Jenkins can call it directly with AWS CLI.

You do **not** need to SSH into the Docker VM just to create resources, as long as:

- Jenkins can reach `LS_ENDPOINT_URL`
- AWS credentials for LocalStack are valid
- AWS CLI is installed on the Jenkins agent

## What this project manages now

`bash scripts/localstack_infra.sh` handles these resources in command order:

1. ECR repository
2. VPC
3. Subnet A
4. Subnet B
5. Optional EKS/IAM (only when `ENABLE_EKS=true`)

Supported actions:

- `preflight`: checks tools + LocalStack health + STS
- `apply`: create/update resources
- `destroy`: delete resources
- `status`: read current resource state

AWS CLI v1 and v2 are both supported.

## Repository layout

- `Jenkinsfile`: CI pipeline that runs the AWS CLI workflow
- `scripts/localstack_infra.sh`: main ordered command script
- `config/infra.env.example`: optional defaults template
- `artifacts/`: generated at runtime (`outputs.env`, health json)

## Jenkins credentials required

Create these credentials as **Secret text** in Jenkins:

- `LS_AWS_ACCESS_KEY_ID`
- `LS_AWS_SECRET_ACCESS_KEY`
- `LS_ENDPOINT_URL`

Example endpoint value:

- `https://localstack.nauthappstest.tech`

## Jenkins pipeline flow

1. Checkout
2. Tooling check (`bash`, `curl`, `aws`)
3. Preflight against LocalStack
4. Manual action choice (`apply`, `destroy`, `status`, `abort`)
5. Execute `scripts/localstack_infra.sh`
6. Show and archive `artifacts/outputs.env`

## Optional defaults file

If you want fixed defaults in repo, copy:

```bash
cp config/infra.env.example config/infra.env
```

Then edit `config/infra.env` for names/CIDRs/AZs.

Do not store credentials in `config/infra.env`.

## Run locally (without Jenkins)

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_REGION=us-east-1
export LS_ENDPOINT_URL=https://localstack.nauthappstest.tech

bash scripts/localstack_infra.sh preflight
bash scripts/localstack_infra.sh apply
bash scripts/localstack_infra.sh status
# bash scripts/localstack_infra.sh destroy
```

## EKS note for beginners

EKS support in LocalStack can be partial depending on version/edition.

- Keep `ENABLE_EKS=false` for stable learning runs.
- Turn `ENABLE_EKS=true` only when you intentionally want to test EKS behavior.

## Security note

If LocalStack is publicly reachable, protect it with network rules and credentials.
Do not leave admin-like endpoints open to the internet without restrictions.
