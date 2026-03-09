#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${PROJECT_ROOT}/artifacts"
ENV_FILE="${PROJECT_ROOT}/config/infra.env"
OUTPUT_FILE="${ARTIFACTS_DIR}/outputs.env"
HEALTH_FILE="${ARTIFACTS_DIR}/localstack-health.json"
AWS_BIN="${AWS_BIN:-aws}"
AWS_CLI_MAJOR="unknown"
AWS_GLOBAL_ARGS=()

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
  bash scripts/localstack_infra.sh preflight
  bash scripts/localstack_infra.sh apply
  bash scripts/localstack_infra.sh destroy
  bash scripts/localstack_infra.sh status

Required environment variables:
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  LS_ENDPOINT_URL

Optional environment variables:
  AWS_REGION (default: us-east-1)
  ENABLE_EKS (default: false)

Optional defaults file:
  config/infra.env
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

  ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-hello-spring}"

  VPC_NAME="${VPC_NAME:-localstack-main-vpc}"
  VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"

  SUBNET_A_NAME="${SUBNET_A_NAME:-localstack-subnet-a}"
  SUBNET_B_NAME="${SUBNET_B_NAME:-localstack-subnet-b}"
  SUBNET_A_CIDR="${SUBNET_A_CIDR:-10.0.1.0/24}"
  SUBNET_B_CIDR="${SUBNET_B_CIDR:-10.0.2.0/24}"
  SUBNET_A_AZ="${SUBNET_A_AZ:-${AWS_REGION}a}"
  SUBNET_B_AZ="${SUBNET_B_AZ:-${AWS_REGION}b}"

  ENABLE_EKS="$(printf '%s' "${ENABLE_EKS:-false}" | tr '[:upper:]' '[:lower:]')"
  EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-localstack-eks-cluster}"
  EKS_NODE_GROUP_NAME="${EKS_NODE_GROUP_NAME:-localstack-eks-node-group}"
  EKS_NODE_INSTANCE_TYPE="${EKS_NODE_INSTANCE_TYPE:-t3.medium}"
  EKS_NODE_DESIRED_SIZE="${EKS_NODE_DESIRED_SIZE:-1}"
  EKS_NODE_MIN_SIZE="${EKS_NODE_MIN_SIZE:-1}"
  EKS_NODE_MAX_SIZE="${EKS_NODE_MAX_SIZE:-2}"
}

detect_aws_cli() {
  command -v "${AWS_BIN}" >/dev/null 2>&1 || die "AWS CLI not found. Install awscli v1 or v2."
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

run_preflight() {
  mkdir -p "${ARTIFACTS_DIR}"

  require_env AWS_ACCESS_KEY_ID
  require_env AWS_SECRET_ACCESS_KEY
  require_env LS_ENDPOINT_URL

  command -v curl >/dev/null 2>&1 || die "curl is required."
  detect_aws_cli

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_REGION
  export AWS_DEFAULT_REGION="${AWS_REGION}"
  export AWS_PAGER=""

  local health_url="${LS_ENDPOINT_URL}/_localstack/health"
  log "Checking LocalStack health endpoint: ${health_url}"
  curl -fsS --retry 5 --retry-delay 2 --retry-all-errors --max-time 20 "${health_url}" > "${HEALTH_FILE}"

  if grep -qi '"running"[[:space:]]*:[[:space:]]*false' "${HEALTH_FILE}"; then
    cat "${HEALTH_FILE}" >&2
    die "LocalStack reported one or more services as not running."
  fi

  aws_localstack sts get-caller-identity >/dev/null
  log "Preflight checks passed."
}

get_vpc_id() {
  local value
  value="$(aws_localstack ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${VPC_NAME}" \
    --query "Vpcs[0].VpcId" \
    --output text 2>/dev/null || true)"
  none_to_empty "${value}"
}

get_subnet_id_by_name() {
  local subnet_name="$1"
  local vpc_id="$2"
  local value
  value="$(aws_localstack ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=${subnet_name}" \
    --query "Subnets[0].SubnetId" \
    --output text 2>/dev/null || true)"
  none_to_empty "${value}"
}

role_exists() {
  local role_name="$1"
  aws_localstack iam get-role --role-name "${role_name}" >/dev/null 2>&1
}

policy_arn_by_name() {
  local policy_name="$1"
  local value
  value="$(aws_localstack iam list-policies \
    --scope Local \
    --query "Policies[?PolicyName=='${policy_name}'].Arn | [0]" \
    --output text 2>/dev/null || true)"
  none_to_empty "${value}"
}

ensure_ecr_repository() {
  if aws_localstack ecr describe-repositories --repository-names "${ECR_REPOSITORY_NAME}" >/dev/null 2>&1; then
    log "ECR repository exists: ${ECR_REPOSITORY_NAME}"
  else
    log "Creating ECR repository: ${ECR_REPOSITORY_NAME}"
    aws_localstack ecr create-repository --repository-name "${ECR_REPOSITORY_NAME}" >/dev/null
  fi

  ECR_REPOSITORY_URI="$(aws_localstack ecr describe-repositories \
    --repository-names "${ECR_REPOSITORY_NAME}" \
    --query "repositories[0].repositoryUri" \
    --output text)"
}

ensure_vpc() {
  VPC_ID="$(get_vpc_id)"
  if [[ -n "${VPC_ID}" ]]; then
    log "VPC exists: ${VPC_ID} (${VPC_NAME})"
    return
  fi

  log "Creating VPC (${VPC_NAME}) with CIDR ${VPC_CIDR}"
  VPC_ID="$(aws_localstack ec2 create-vpc \
    --cidr-block "${VPC_CIDR}" \
    --query "Vpc.VpcId" \
    --output text)"
  aws_localstack ec2 create-tags --resources "${VPC_ID}" --tags "Key=Name,Value=${VPC_NAME}" >/dev/null
}

ensure_subnet() {
  local subnet_name="$1"
  local subnet_cidr="$2"
  local subnet_az="$3"
  local subnet_id

  subnet_id="$(get_subnet_id_by_name "${subnet_name}" "${VPC_ID}")"
  if [[ -n "${subnet_id}" ]]; then
    log "Subnet exists: ${subnet_id} (${subnet_name})"
    printf '%s' "${subnet_id}"
    return
  fi

  log "Creating subnet ${subnet_name} (${subnet_cidr} in ${subnet_az})"
  subnet_id="$(aws_localstack ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "${subnet_cidr}" \
    --availability-zone "${subnet_az}" \
    --query "Subnet.SubnetId" \
    --output text)"
  aws_localstack ec2 create-tags --resources "${subnet_id}" --tags "Key=Name,Value=${subnet_name}" >/dev/null

  if ! aws_localstack ec2 modify-subnet-attribute --subnet-id "${subnet_id}" --map-public-ip-on-launch >/dev/null 2>&1; then
    warn "Could not set map-public-ip-on-launch for ${subnet_name}; continuing."
  fi

  printf '%s' "${subnet_id}"
}

ensure_iam_role() {
  local role_name="$1"
  local assume_role_doc="$2"

  if role_exists "${role_name}"; then
    log "IAM role exists: ${role_name}"
  else
    log "Creating IAM role: ${role_name}"
    aws_localstack iam create-role \
      --role-name "${role_name}" \
      --assume-role-policy-document "file://${assume_role_doc}" >/dev/null
  fi

  aws_localstack iam get-role --role-name "${role_name}" --query "Role.Arn" --output text
}

ensure_policy() {
  local policy_name="$1"
  local policy_doc="$2"
  local policy_arn

  policy_arn="$(policy_arn_by_name "${policy_name}")"
  if [[ -n "${policy_arn}" ]]; then
    log "IAM policy exists: ${policy_name}"
    printf '%s' "${policy_arn}"
    return
  fi

  log "Creating IAM policy: ${policy_name}"
  policy_arn="$(aws_localstack iam create-policy \
    --policy-name "${policy_name}" \
    --policy-document "file://${policy_doc}" \
    --query "Policy.Arn" \
    --output text)"
  printf '%s' "${policy_arn}"
}

ensure_policy_attached() {
  local role_name="$1"
  local policy_arn="$2"
  local attached_count

  attached_count="$(none_to_empty "$(aws_localstack iam list-attached-role-policies \
    --role-name "${role_name}" \
    --query "AttachedPolicies[?PolicyArn=='${policy_arn}'] | length(@)" \
    --output text 2>/dev/null || true)")"

  if [[ -z "${attached_count}" || "${attached_count}" == "0" ]]; then
    log "Attaching policy ${policy_arn} to role ${role_name}"
    aws_localstack iam attach-role-policy --role-name "${role_name}" --policy-arn "${policy_arn}" >/dev/null
  else
    log "Policy already attached: ${policy_arn} -> ${role_name}"
  fi
}

wait_for_eks_cluster_active() {
  local attempt status
  for attempt in $(seq 1 20); do
    status="$(none_to_empty "$(aws_localstack eks describe-cluster \
      --name "${EKS_CLUSTER_NAME}" \
      --query "cluster.status" \
      --output text 2>/dev/null || true)")"

    case "${status}" in
      ACTIVE)
        log "EKS cluster is ACTIVE: ${EKS_CLUSTER_NAME}"
        return
        ;;
      CREATING|"")
        sleep 5
        ;;
      *)
        warn "Unexpected EKS cluster status (${status}); continuing."
        return
        ;;
    esac
  done

  warn "Timed out waiting for EKS cluster to become ACTIVE; continuing."
}

ensure_eks_resources() {
  if [[ "${ENABLE_EKS}" != "true" ]]; then
    log "ENABLE_EKS=false, skipping EKS resources."
    EKS_CLUSTER_ACTUAL=""
    EKS_NODEGROUP_ACTUAL=""
    return
  fi

  log "ENABLE_EKS=true, provisioning EKS resources."
  local tmp_dir
  local cluster_role_name="${EKS_CLUSTER_NAME}-role"
  local node_role_name="${EKS_NODE_GROUP_NAME}-role"
  local cluster_policy_name="${EKS_CLUSTER_NAME}-policy"
  local node_policy_name="${EKS_NODE_GROUP_NAME}-policy"
  local cluster_role_arn cluster_policy_arn node_role_arn node_policy_arn

  tmp_dir="$(mktemp -d)"

  cat > "${tmp_dir}/eks-cluster-assume-role.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "eks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

  cat > "${tmp_dir}/eks-node-assume-role.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

  cat > "${tmp_dir}/eks-cluster-policy.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "eks:*",
        "iam:PassRole",
        "sts:AssumeRole"
      ],
      "Resource": "*"
    }
  ]
}
JSON

  cat > "${tmp_dir}/eks-node-policy.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "ecr:*",
        "eks:*",
        "sts:AssumeRole"
      ],
      "Resource": "*"
    }
  ]
}
JSON

  cluster_role_arn="$(ensure_iam_role "${cluster_role_name}" "${tmp_dir}/eks-cluster-assume-role.json")"
  cluster_policy_arn="$(ensure_policy "${cluster_policy_name}" "${tmp_dir}/eks-cluster-policy.json")"
  ensure_policy_attached "${cluster_role_name}" "${cluster_policy_arn}"

  node_role_arn="$(ensure_iam_role "${node_role_name}" "${tmp_dir}/eks-node-assume-role.json")"
  node_policy_arn="$(ensure_policy "${node_policy_name}" "${tmp_dir}/eks-node-policy.json")"
  ensure_policy_attached "${node_role_name}" "${node_policy_arn}"

  if aws_localstack eks describe-cluster --name "${EKS_CLUSTER_NAME}" >/dev/null 2>&1; then
    log "EKS cluster exists: ${EKS_CLUSTER_NAME}"
  else
    log "Creating EKS cluster: ${EKS_CLUSTER_NAME}"
    aws_localstack eks create-cluster \
      --name "${EKS_CLUSTER_NAME}" \
      --role-arn "${cluster_role_arn}" \
      --resources-vpc-config "subnetIds=${SUBNET_A_ID},${SUBNET_B_ID}" >/dev/null
  fi

  wait_for_eks_cluster_active

  if aws_localstack eks describe-nodegroup \
    --cluster-name "${EKS_CLUSTER_NAME}" \
    --nodegroup-name "${EKS_NODE_GROUP_NAME}" >/dev/null 2>&1; then
    log "EKS nodegroup exists: ${EKS_NODE_GROUP_NAME}"
  else
    log "Creating EKS nodegroup: ${EKS_NODE_GROUP_NAME}"
    aws_localstack eks create-nodegroup \
      --cluster-name "${EKS_CLUSTER_NAME}" \
      --nodegroup-name "${EKS_NODE_GROUP_NAME}" \
      --subnets "${SUBNET_A_ID}" "${SUBNET_B_ID}" \
      --node-role "${node_role_arn}" \
      --instance-types "${EKS_NODE_INSTANCE_TYPE}" \
      --scaling-config "minSize=${EKS_NODE_MIN_SIZE},maxSize=${EKS_NODE_MAX_SIZE},desiredSize=${EKS_NODE_DESIRED_SIZE}" >/dev/null
  fi

  EKS_CLUSTER_ACTUAL="${EKS_CLUSTER_NAME}"
  EKS_NODEGROUP_ACTUAL="${EKS_NODE_GROUP_NAME}"

  rm -rf "${tmp_dir}"
}

wait_for_nodegroup_deleted() {
  local attempt
  for attempt in $(seq 1 20); do
    if aws_localstack eks describe-nodegroup \
      --cluster-name "${EKS_CLUSTER_NAME}" \
      --nodegroup-name "${EKS_NODE_GROUP_NAME}" >/dev/null 2>&1; then
      sleep 5
    else
      return
    fi
  done

  warn "Timed out waiting for EKS nodegroup deletion; continuing."
}

wait_for_cluster_deleted() {
  local attempt
  for attempt in $(seq 1 20); do
    if aws_localstack eks describe-cluster --name "${EKS_CLUSTER_NAME}" >/dev/null 2>&1; then
      sleep 5
    else
      return
    fi
  done

  warn "Timed out waiting for EKS cluster deletion; continuing."
}

detach_policy_if_attached() {
  local role_name="$1"
  local policy_arn="$2"
  if [[ -z "${policy_arn}" ]]; then
    return
  fi

  if role_exists "${role_name}"; then
    aws_localstack iam detach-role-policy --role-name "${role_name}" --policy-arn "${policy_arn}" >/dev/null 2>&1 || true
  fi
}

delete_policy_if_exists() {
  local policy_name="$1"
  local policy_arn
  policy_arn="$(policy_arn_by_name "${policy_name}")"
  if [[ -n "${policy_arn}" ]]; then
    log "Deleting IAM policy: ${policy_name}"
    aws_localstack iam delete-policy --policy-arn "${policy_arn}" >/dev/null 2>&1 || true
  fi
}

delete_role_if_exists() {
  local role_name="$1"
  if role_exists "${role_name}"; then
    log "Deleting IAM role: ${role_name}"
    aws_localstack iam delete-role --role-name "${role_name}" >/dev/null 2>&1 || true
  fi
}

destroy_eks_resources() {
  local cluster_role_name="${EKS_CLUSTER_NAME}-role"
  local node_role_name="${EKS_NODE_GROUP_NAME}-role"
  local cluster_policy_name="${EKS_CLUSTER_NAME}-policy"
  local node_policy_name="${EKS_NODE_GROUP_NAME}-policy"
  local cluster_policy_arn node_policy_arn

  if [[ "${ENABLE_EKS}" != "true" ]]; then
    log "ENABLE_EKS=false. Still checking for leftover EKS/IAM resources to delete safely."
  fi

  if aws_localstack eks describe-nodegroup \
    --cluster-name "${EKS_CLUSTER_NAME}" \
    --nodegroup-name "${EKS_NODE_GROUP_NAME}" >/dev/null 2>&1; then
    log "Deleting EKS nodegroup: ${EKS_NODE_GROUP_NAME}"
    aws_localstack eks delete-nodegroup \
      --cluster-name "${EKS_CLUSTER_NAME}" \
      --nodegroup-name "${EKS_NODE_GROUP_NAME}" >/dev/null 2>&1 || true
    wait_for_nodegroup_deleted
  fi

  if aws_localstack eks describe-cluster --name "${EKS_CLUSTER_NAME}" >/dev/null 2>&1; then
    log "Deleting EKS cluster: ${EKS_CLUSTER_NAME}"
    aws_localstack eks delete-cluster --name "${EKS_CLUSTER_NAME}" >/dev/null 2>&1 || true
    wait_for_cluster_deleted
  fi

  cluster_policy_arn="$(policy_arn_by_name "${cluster_policy_name}")"
  node_policy_arn="$(policy_arn_by_name "${node_policy_name}")"

  detach_policy_if_attached "${cluster_role_name}" "${cluster_policy_arn}"
  detach_policy_if_attached "${node_role_name}" "${node_policy_arn}"

  delete_policy_if_exists "${cluster_policy_name}"
  delete_policy_if_exists "${node_policy_name}"
  delete_role_if_exists "${cluster_role_name}"
  delete_role_if_exists "${node_role_name}"

  EKS_CLUSTER_ACTUAL=""
  EKS_NODEGROUP_ACTUAL=""
}

delete_subnet_if_exists() {
  local subnet_name="$1"
  local subnet_id
  subnet_id="$(get_subnet_id_by_name "${subnet_name}" "${VPC_ID}")"
  if [[ -n "${subnet_id}" ]]; then
    log "Deleting subnet ${subnet_name} (${subnet_id})"
    aws_localstack ec2 delete-subnet --subnet-id "${subnet_id}" >/dev/null 2>&1 || true
  fi
}

destroy_core_resources() {
  VPC_ID="$(get_vpc_id)"
  if [[ -n "${VPC_ID}" ]]; then
    delete_subnet_if_exists "${SUBNET_A_NAME}"
    delete_subnet_if_exists "${SUBNET_B_NAME}"
    log "Deleting VPC ${VPC_NAME} (${VPC_ID})"
    aws_localstack ec2 delete-vpc --vpc-id "${VPC_ID}" >/dev/null 2>&1 || true
  else
    log "VPC not found (${VPC_NAME}), skipping VPC delete."
  fi

  if aws_localstack ecr describe-repositories --repository-names "${ECR_REPOSITORY_NAME}" >/dev/null 2>&1; then
    log "Deleting ECR repository: ${ECR_REPOSITORY_NAME}"
    aws_localstack ecr delete-repository --repository-name "${ECR_REPOSITORY_NAME}" --force >/dev/null 2>&1 || true
  else
    log "ECR repository not found (${ECR_REPOSITORY_NAME}), skipping delete."
  fi
}

collect_state() {
  ECR_REPOSITORY_URI="$(none_to_empty "$(aws_localstack ecr describe-repositories \
    --repository-names "${ECR_REPOSITORY_NAME}" \
    --query "repositories[0].repositoryUri" \
    --output text 2>/dev/null || true)")"

  VPC_ID="$(get_vpc_id)"
  SUBNET_A_ID=""
  SUBNET_B_ID=""

  if [[ -n "${VPC_ID}" ]]; then
    SUBNET_A_ID="$(get_subnet_id_by_name "${SUBNET_A_NAME}" "${VPC_ID}")"
    SUBNET_B_ID="$(get_subnet_id_by_name "${SUBNET_B_NAME}" "${VPC_ID}")"
  fi

  EKS_CLUSTER_ACTUAL=""
  EKS_NODEGROUP_ACTUAL=""
  if aws_localstack eks describe-cluster --name "${EKS_CLUSTER_NAME}" >/dev/null 2>&1; then
    EKS_CLUSTER_ACTUAL="${EKS_CLUSTER_NAME}"
  fi
  if aws_localstack eks describe-nodegroup \
    --cluster-name "${EKS_CLUSTER_NAME}" \
    --nodegroup-name "${EKS_NODE_GROUP_NAME}" >/dev/null 2>&1; then
    EKS_NODEGROUP_ACTUAL="${EKS_NODE_GROUP_NAME}"
  fi
}

write_outputs() {
  mkdir -p "${ARTIFACTS_DIR}"
  cat > "${OUTPUT_FILE}" <<EOF
DEPLOYMENT_MODE=awscli
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

run_apply() {
  run_preflight
  ensure_ecr_repository
  ensure_vpc
  SUBNET_A_ID="$(ensure_subnet "${SUBNET_A_NAME}" "${SUBNET_A_CIDR}" "${SUBNET_A_AZ}")"
  SUBNET_B_ID="$(ensure_subnet "${SUBNET_B_NAME}" "${SUBNET_B_CIDR}" "${SUBNET_B_AZ}")"
  ensure_eks_resources
  collect_state
  write_outputs
  log "Apply completed."
}

run_destroy() {
  run_preflight
  destroy_eks_resources
  destroy_core_resources
  collect_state
  write_outputs
  log "Destroy completed."
}

run_status() {
  run_preflight
  collect_state
  write_outputs
  cat "${OUTPUT_FILE}"
  log "Status completed."
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
