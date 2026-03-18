#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${PROJECT_ROOT}/artifacts"
ENV_FILE="${PROJECT_ROOT}/config/k8s.env"
STATUS_FILE="${ARTIFACTS_DIR}/k8s-mail-sync.txt"
SSH_ARGS=()

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash scripts/k8s_mail_env.sh apply

Required environment variables:
  MAIL_HOST
  MAIL_PORT
  MAIL_USERNAME
  MAIL_PASSWORD
  APP_CONTACT_MAIL_FROM

Required target variables:
  K8S_NAMESPACE
  K8S_DEPLOYMENT

Optional defaults file:
  config/k8s.env

Optional access variables:
  K8S_ACCESS_MODE (default: local; supported: local, ssh-docker)
  K8S_REMOTE_HOST
  K8S_REMOTE_PORT (default: 22)
  K8S_REMOTE_USER
  K8S_REMOTE_CONTAINER (default: auto-detect first k3d server-0 container)
  SSH_KEY_FILE (used when K8S_ACCESS_MODE=ssh-docker)

Optional target variables:
  K8S_MAIL_SECRET_NAME (default: mail-secret)
  K8S_MAIL_CONFIGMAP_NAME (default: mail-config)
EOF
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "${name} is required."
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
  K8S_ACCESS_MODE="${K8S_ACCESS_MODE:-local}"
  K8S_NAMESPACE="${K8S_NAMESPACE:-hello-spring}"
  K8S_DEPLOYMENT="${K8S_DEPLOYMENT:-hello-spring}"
  K8S_REMOTE_HOST="${K8S_REMOTE_HOST:-}"
  K8S_REMOTE_PORT="${K8S_REMOTE_PORT:-22}"
  K8S_REMOTE_USER="${K8S_REMOTE_USER:-${SSH_USERNAME:-}}"
  K8S_REMOTE_CONTAINER="${K8S_REMOTE_CONTAINER:-}"
  K8S_MAIL_SECRET_NAME="${K8S_MAIL_SECRET_NAME:-mail-secret}"
  K8S_MAIL_CONFIGMAP_NAME="${K8S_MAIL_CONFIGMAP_NAME:-mail-config}"
}

detect_tools() {
  case "${K8S_ACCESS_MODE}" in
    local)
      command -v kubectl >/dev/null 2>&1 || die "kubectl not found."
      ;;
    ssh-docker)
      command -v ssh >/dev/null 2>&1 || die "ssh not found."
      ;;
    *)
      die "Unsupported K8S_ACCESS_MODE: ${K8S_ACCESS_MODE}"
      ;;
  esac
}

prepare_ssh() {
  [[ "${K8S_ACCESS_MODE}" == "ssh-docker" ]] || return
  require_env K8S_REMOTE_HOST
  [[ -n "${K8S_REMOTE_USER}" ]] || die "K8S_REMOTE_USER is required when K8S_ACCESS_MODE=ssh-docker."

  SSH_ARGS=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -p "${K8S_REMOTE_PORT}"
  )

  if [[ -n "${SSH_KEY_FILE:-}" ]]; then
    SSH_ARGS+=(-i "${SSH_KEY_FILE}")
  fi
}

check_ssh_connectivity() {
  [[ "${K8S_ACCESS_MODE}" == "ssh-docker" ]] || return
  if ! run_ssh true >/dev/null 2>&1; then
    die "SSH connection to ${K8S_REMOTE_HOST} failed. Use the Azure VM public IP or public DNS reachable from Jenkins, not the Azure resource name or a local ~/.ssh/config alias."
  fi
}

ssh_target() {
  printf '%s@%s' "${K8S_REMOTE_USER}" "${K8S_REMOTE_HOST}"
}

run_ssh() {
  ssh "${SSH_ARGS[@]}" "$(ssh_target)" "$@"
}

detect_remote_container() {
  [[ "${K8S_ACCESS_MODE}" == "ssh-docker" ]] || return
  if [[ -n "${K8S_REMOTE_CONTAINER}" ]]; then
    log "Using configured remote Kubernetes container: ${K8S_REMOTE_CONTAINER}"
    return
  fi

  log "Auto-detecting k3d server container on ${K8S_REMOTE_HOST}"
  K8S_REMOTE_CONTAINER="$(run_ssh sh -lc "docker ps --format '{{.Names}}' | grep -E '^k3d-.*-server-0$' | head -n 1")"
  [[ -n "${K8S_REMOTE_CONTAINER}" ]] || die "Could not auto-detect a k3d server container on ${K8S_REMOTE_HOST}."
  log "Detected remote Kubernetes container: ${K8S_REMOTE_CONTAINER}"
}

run_kubectl() {
  case "${K8S_ACCESS_MODE}" in
    local)
      kubectl "$@"
      ;;
    ssh-docker)
      run_ssh docker exec -i "${K8S_REMOTE_CONTAINER}" kubectl "$@"
      ;;
    *)
      die "Unsupported K8S_ACCESS_MODE: ${K8S_ACCESS_MODE}"
      ;;
  esac
}

yaml_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

secret_manifest() {
  cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${K8S_MAIL_SECRET_NAME}
  namespace: ${K8S_NAMESPACE}
type: Opaque
stringData:
  MAIL_USERNAME: '$(yaml_quote "${MAIL_USERNAME}")'
  MAIL_PASSWORD: '$(yaml_quote "${MAIL_PASSWORD}")'
EOF
}

configmap_manifest() {
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${K8S_MAIL_CONFIGMAP_NAME}
  namespace: ${K8S_NAMESPACE}
data:
  MAIL_HOST: '$(yaml_quote "${MAIL_HOST}")'
  MAIL_PORT: '$(yaml_quote "${MAIL_PORT}")'
  APP_CONTACT_MAIL_FROM: '$(yaml_quote "${APP_CONTACT_MAIL_FROM}")'
EOF
}

validate_target() {
  [[ -n "${K8S_DEPLOYMENT}" ]] || die "K8S_DEPLOYMENT is required."
  run_kubectl -n "${K8S_NAMESPACE}" get deployment "${K8S_DEPLOYMENT}" >/dev/null 2>&1 || \
    die "Deployment ${K8S_DEPLOYMENT} was not found in namespace ${K8S_NAMESPACE}."
}

apply_secret() {
  secret_manifest | run_kubectl apply -f - >/dev/null
}

apply_configmap() {
  configmap_manifest | run_kubectl apply -f - >/dev/null
}

update_deployment() {
  run_kubectl -n "${K8S_NAMESPACE}" set env "deployment/${K8S_DEPLOYMENT}" \
    --from="configmap/${K8S_MAIL_CONFIGMAP_NAME}" \
    --from="secret/${K8S_MAIL_SECRET_NAME}" >/dev/null

  # Force new pods so the refreshed Secret/ConfigMap values are picked up.
  run_kubectl -n "${K8S_NAMESPACE}" rollout restart "deployment/${K8S_DEPLOYMENT}" >/dev/null
  run_kubectl -n "${K8S_NAMESPACE}" rollout status "deployment/${K8S_DEPLOYMENT}" --timeout=180s
}

write_status() {
  mkdir -p "${ARTIFACTS_DIR}"
  cat > "${STATUS_FILE}" <<EOF
ACTION=apply
K8S_ACCESS_MODE=${K8S_ACCESS_MODE}
K8S_NAMESPACE=${K8S_NAMESPACE}
K8S_DEPLOYMENT=${K8S_DEPLOYMENT}
K8S_REMOTE_HOST=${K8S_REMOTE_HOST}
K8S_REMOTE_CONTAINER=${K8S_REMOTE_CONTAINER}
K8S_MAIL_SECRET_NAME=${K8S_MAIL_SECRET_NAME}
K8S_MAIL_CONFIGMAP_NAME=${K8S_MAIL_CONFIGMAP_NAME}
CONFIGURED_KEYS=MAIL_HOST,MAIL_PORT,MAIL_USERNAME,MAIL_PASSWORD,APP_CONTACT_MAIL_FROM
EOF
  log "Kubernetes mail sync summary written to ${STATUS_FILE}"
}

run_apply() {
  detect_tools
  require_env MAIL_HOST
  require_env MAIL_PORT
  require_env MAIL_USERNAME
  require_env MAIL_PASSWORD
  require_env APP_CONTACT_MAIL_FROM
  prepare_ssh
  check_ssh_connectivity
  detect_remote_container
  validate_target
  apply_secret
  apply_configmap
  update_deployment
  write_status
  log "Kubernetes mail environment sync completed."
}

main() {
  local action="${1:-}"
  if [[ -z "${action}" ]]; then
    usage
    exit 1
  fi

  load_env_file
  set_defaults

  case "${action}" in
    apply)
      run_apply
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
