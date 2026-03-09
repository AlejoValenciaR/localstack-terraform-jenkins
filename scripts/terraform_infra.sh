#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${PROJECT_ROOT}/artifacts"
ENV_FILE="${PROJECT_ROOT}/config/terraform.env"
OUTPUT_FILE="${ARTIFACTS_DIR}/outputs.env"
TF_OUTPUTS_TEXT_FILE="${ARTIFACTS_DIR}/terraform-outputs.txt"
TF_OUTPUTS_JSON_FILE="${ARTIFACTS_DIR}/terraform-outputs.json"
TF_STATE_LIST_FILE="${ARTIFACTS_DIR}/terraform-state-list.txt"
AWS_BIN="${AWS_BIN:-aws}"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
AWS_CLI_MAJOR="unknown"
AWS_GLOBAL_ARGS=()

ECR_REPOSITORY_NAME=""
ECR_REPOSITORY_URI=""
VPC_ID=""
SUBNET_A_ID=""
SUBNET_B_ID=""
EKS_CLUSTER_ACTUAL=""
EKS_NODEGROUP_ACTUAL=""

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

warn() {
  printf '[%s] WARN: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash scripts/terraform_infra.sh preflight
  bash scripts/terraform_infra.sh apply
  bash scripts/terraform_infra.sh destroy
  bash scripts/terraform_infra.sh status

Required environment variables:
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  LS_ENDPOINT_URL

Required environment variables when TF_DISABLE_BACKEND=false (default):
  ARM_CLIENT_ID
  ARM_CLIENT_SECRET
  ARM_TENANT_ID
  ARM_SUBSCRIPTION_ID
  TFSTATE_RESOURCE_GROUP

Optional environment variables:
  AWS_REGION (default: us-east-1)
  ENABLE_EKS (default: false)
  TF_PARALLELISM (default: 1)
  TF_DISABLE_BACKEND (default: false)
  TFSTATE_STORAGE_ACCOUNT (default: alejatfstate2026demo)
  TFSTATE_CONTAINER (default: tfstate)
  TFSTATE_KEY (default: localstack-terraform-jenkins.tfstate)

Optional defaults file:
  config/terraform.env
EOF
}

none_to_empty() {
  local value="${1:-}"
  case "${value}" in
    None|null|"")
      printf ''
      ;;
    *)
      printf '%s' "${value}"
      ;;
  esac
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "${name} is required."
}

validate_boolean() {
  local name="$1"
  case "${!name}" in
    true|false)
      ;;
    *)
      die "${name} must be true or false (received: ${!name})."
      ;;
  esac
}

load_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    log "Loading defaults from ${ENV_FILE}"
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  fi
}

set_defaults() {
  AWS_REGION="${AWS_REGION:-us-east-1}"
  LS_ENDPOINT_URL="${LS_ENDPOINT_URL:-}"
  LS_ENDPOINT_URL="${LS_ENDPOINT_URL%/}"

  ENABLE_EKS="$(printf '%s' "${ENABLE_EKS:-false}" | tr '[:upper:]' '[:lower:]')"
  TF_DISABLE_BACKEND="$(printf '%s' "${TF_DISABLE_BACKEND:-false}" | tr '[:upper:]' '[:lower:]')"
  TF_PARALLELISM="${TF_PARALLELISM:-1}"

  TFSTATE_STORAGE_ACCOUNT="${TFSTATE_STORAGE_ACCOUNT:-alejatfstate2026demo}"
  TFSTATE_CONTAINER="${TFSTATE_CONTAINER:-tfstate}"
  TFSTATE_KEY="${TFSTATE_KEY:-localstack-terraform-jenkins.tfstate}"
  TFSTATE_RESOURCE_GROUP="${TFSTATE_RESOURCE_GROUP:-}"

  ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-hello-spring}"
  VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
  SUBNET_1_CIDR="${SUBNET_1_CIDR:-10.0.1.0/24}"
  SUBNET_2_CIDR="${SUBNET_2_CIDR:-10.0.2.0/24}"
  EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-localstack-eks-cluster}"
  EKS_NODE_GROUP_NAME="${EKS_NODE_GROUP_NAME:-localstack-eks-node-group}"
  EKS_NODE_INSTANCE_TYPES="${EKS_NODE_INSTANCE_TYPES:-t3.medium}"
  EKS_NODE_DESIRED_SIZE="${EKS_NODE_DESIRED_SIZE:-1}"
  EKS_NODE_MIN_SIZE="${EKS_NODE_MIN_SIZE:-1}"
  EKS_NODE_MAX_SIZE="${EKS_NODE_MAX_SIZE:-2}"
}

detect_tools() {
  command -v curl >/dev/null 2>&1 || die "curl is required."
  command -v "${AWS_BIN}" >/dev/null 2>&1 || die "AWS CLI not found."
  command -v "${TERRAFORM_BIN}" >/dev/null 2>&1 || die "terraform not found."
}

detect_aws_cli() {
  local version_output
  version_output="$("${AWS_BIN}" --version 2>&1 || true)"
  [[ -n "${version_output}" ]] || die "Could not read AWS CLI version."

  if [[ "${version_output}" == aws-cli/2* ]]; then
    AWS_CLI_MAJOR="2"
    AWS_GLOBAL_ARGS=(--no-cli-pager --region "${AWS_REGION}" --endpoint-url "${LS_ENDPOINT_URL}")
  elif [[ "${version_output}" == aws-cli/1* ]]; then
    AWS_CLI_MAJOR="1"
    AWS_GLOBAL_ARGS=(--region "${AWS_REGION}" --endpoint-url "${LS_ENDPOINT_URL}")
  else
    AWS_CLI_MAJOR="unknown"
    AWS_GLOBAL_ARGS=(--region "${AWS_REGION}" --endpoint-url "${LS_ENDPOINT_URL}")
  fi

  log "AWS CLI detected (${AWS_CLI_MAJOR}): ${version_output}"
}

aws_localstack() {
  "${AWS_BIN}" "${AWS_GLOBAL_ARGS[@]}" "$@"
}

export_runtime_env() {
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_REGION
  export AWS_DEFAULT_REGION="${AWS_REGION}"
  export AWS_PAGER=""

  export TF_IN_AUTOMATION="${TF_IN_AUTOMATION:-true}"
  export TF_INPUT="${TF_INPUT:-false}"
  export TF_CLI_ARGS="${TF_CLI_ARGS:--no-color}"

  export TF_VAR_aws_region="${AWS_REGION}"
  export TF_VAR_aws_access_key="${AWS_ACCESS_KEY_ID}"
  export TF_VAR_aws_secret_key="${AWS_SECRET_ACCESS_KEY}"
  export TF_VAR_localstack_endpoint_url="${LS_ENDPOINT_URL}"
  export TF_VAR_enable_eks="${ENABLE_EKS}"

  export TF_VAR_ecr_repository_name="${ECR_REPOSITORY_NAME}"
  export TF_VAR_vpc_cidr="${VPC_CIDR}"
  export TF_VAR_subnet_1_cidr="${SUBNET_1_CIDR}"
  export TF_VAR_subnet_2_cidr="${SUBNET_2_CIDR}"
  export TF_VAR_eks_cluster_name="${EKS_CLUSTER_NAME}"
  export TF_VAR_eks_node_group_name="${EKS_NODE_GROUP_NAME}"
  export TF_VAR_eks_node_instance_types="[\"${EKS_NODE_INSTANCE_TYPES}\"]"
  export TF_VAR_eks_node_desired_size="${EKS_NODE_DESIRED_SIZE}"
  export TF_VAR_eks_node_min_size="${EKS_NODE_MIN_SIZE}"
  export TF_VAR_eks_node_max_size="${EKS_NODE_MAX_SIZE}"
}

run_localstack_preflight() {
  local health_url="${LS_ENDPOINT_URL}/_localstack/health"
  log "Checking LocalStack health endpoint: ${health_url}"
  curl -fsS --retry 5 --retry-delay 2 --retry-all-errors --max-time 20 "${health_url}" > /dev/null

  aws_localstack sts get-caller-identity >/dev/null
  log "LocalStack preflight checks passed."
}

ensure_backend_auth() {
  if [[ "${TF_DISABLE_BACKEND}" == "true" ]]; then
    log "TF_DISABLE_BACKEND=true, Terraform init will skip remote backend."
    return
  fi

  require_env ARM_CLIENT_ID
  require_env ARM_CLIENT_SECRET
  require_env ARM_TENANT_ID
  require_env ARM_SUBSCRIPTION_ID
  require_env TFSTATE_RESOURCE_GROUP

  export ARM_USE_AZUREAD="${ARM_USE_AZUREAD:-true}"
  export ARM_CLIENT_ID
  export ARM_CLIENT_SECRET
  export ARM_TENANT_ID
  export ARM_SUBSCRIPTION_ID
}

terraform_init() {
  if [[ "${TF_DISABLE_BACKEND}" == "true" ]]; then
    "${TERRAFORM_BIN}" init -reconfigure -input=false -backend=false
    return
  fi

  ensure_backend_auth

  "${TERRAFORM_BIN}" init -reconfigure -input=false \
    -backend-config="resource_group_name=${TFSTATE_RESOURCE_GROUP}" \
    -backend-config="storage_account_name=${TFSTATE_STORAGE_ACCOUNT}" \
    -backend-config="container_name=${TFSTATE_CONTAINER}" \
    -backend-config="key=${TFSTATE_KEY}"
}

terraform_fmt_validate() {
  "${TERRAFORM_BIN}" fmt -check -recursive
  "${TERRAFORM_BIN}" validate
}

terraform_output_raw() {
  local name="$1"
  none_to_empty "$("${TERRAFORM_BIN}" output -raw "${name}" 2>/dev/null || true)"
}

terraform_output_json() {
  local name="$1"
  none_to_empty "$("${TERRAFORM_BIN}" output -json "${name}" 2>/dev/null || true)"
}

collect_state() {
  mkdir -p "${ARTIFACTS_DIR}"

  if ! "${TERRAFORM_BIN}" output > "${TF_OUTPUTS_TEXT_FILE}" 2>/dev/null; then
    warn "Terraform outputs are not available (state may be empty)."
    : > "${TF_OUTPUTS_TEXT_FILE}"
  fi

  if ! "${TERRAFORM_BIN}" output -json > "${TF_OUTPUTS_JSON_FILE}" 2>/dev/null; then
    echo '{}' > "${TF_OUTPUTS_JSON_FILE}"
  fi

  if ! "${TERRAFORM_BIN}" state list > "${TF_STATE_LIST_FILE}" 2>/dev/null; then
    echo "# no terraform resources found in state" > "${TF_STATE_LIST_FILE}"
  fi

  ECR_REPOSITORY_NAME="$(terraform_output_raw ecr_repository_name)"
  ECR_REPOSITORY_URI="$(terraform_output_raw ecr_repository_url)"
  VPC_ID="$(terraform_output_raw vpc_id)"

  SUBNET_A_ID=""
  SUBNET_B_ID=""
  local subnet_json subnet_compact
  subnet_json="$(terraform_output_json subnet_ids)"
  if [[ -n "${subnet_json}" && "${subnet_json}" != "null" ]]; then
    subnet_compact="$(printf '%s' "${subnet_json}" | tr -d '[]"[:space:]')"
    if [[ -n "${subnet_compact}" ]]; then
      IFS=',' read -r SUBNET_A_ID SUBNET_B_ID _ <<< "${subnet_compact}"
    fi
  fi

  EKS_CLUSTER_ACTUAL="$(terraform_output_raw eks_cluster_name)"
  EKS_NODEGROUP_ACTUAL="$(terraform_output_raw eks_node_group_name)"
}

write_outputs() {
  mkdir -p "${ARTIFACTS_DIR}"
  cat > "${OUTPUT_FILE}" <<EOF
DEPLOYMENT_MODE=terraform
AWS_REGION=${AWS_REGION}
LS_ENDPOINT_URL=${LS_ENDPOINT_URL}
ECR_REPOSITORY_NAME=${ECR_REPOSITORY_NAME}
ECR_REPOSITORY_URI=${ECR_REPOSITORY_URI}
VPC_ID=${VPC_ID}
SUBNET_A_ID=${SUBNET_A_ID}
SUBNET_B_ID=${SUBNET_B_ID}
ENABLE_EKS=${ENABLE_EKS}
EKS_CLUSTER_NAME=${EKS_CLUSTER_ACTUAL}
EKS_NODE_GROUP_NAME=${EKS_NODEGROUP_ACTUAL}
EOF
  log "Outputs written to ${OUTPUT_FILE}"
}

run_preflight() {
  detect_tools
  require_env AWS_ACCESS_KEY_ID
  require_env AWS_SECRET_ACCESS_KEY
  require_env LS_ENDPOINT_URL
  export_runtime_env
  detect_aws_cli
  run_localstack_preflight
  "${TERRAFORM_BIN}" version
}

run_apply() {
  run_preflight
  terraform_init
  terraform_fmt_validate
  "${TERRAFORM_BIN}" plan -parallelism="${TF_PARALLELISM}" -var="enable_eks=${ENABLE_EKS}" -out=tfplan
  "${TERRAFORM_BIN}" apply -parallelism="${TF_PARALLELISM}" -auto-approve tfplan
  collect_state
  write_outputs
  log "Terraform apply completed."
}

run_destroy() {
  run_preflight
  terraform_init
  "${TERRAFORM_BIN}" plan -parallelism="${TF_PARALLELISM}" -destroy -var="enable_eks=${ENABLE_EKS}" -out=tfplan
  "${TERRAFORM_BIN}" apply -parallelism="${TF_PARALLELISM}" -auto-approve tfplan
  collect_state
  write_outputs
  log "Terraform destroy completed."
}

run_status() {
  run_preflight
  terraform_init
  collect_state
  write_outputs
  cat "${OUTPUT_FILE}"
  log "Terraform status completed."
}

main() {
  local action="${1:-}"
  if [[ -z "${action}" ]]; then
    usage
    exit 1
  fi

  load_env_file
  set_defaults
  validate_boolean ENABLE_EKS
  validate_boolean TF_DISABLE_BACKEND

  case "${action}" in
    preflight)
      run_preflight
      ;;
    apply)
      run_apply
      ;;
    destroy)
      run_destroy
      ;;
    status)
      run_status
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
