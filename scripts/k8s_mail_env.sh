#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${PROJECT_ROOT}/artifacts"
ENV_FILE="${PROJECT_ROOT}/config/k8s.env"
STATUS_FILE="${ARTIFACTS_DIR}/k8s-mail-sync.txt"

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
  K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
  K8S_DEPLOYMENT="${K8S_DEPLOYMENT:-}"
  K8S_MAIL_SECRET_NAME="${K8S_MAIL_SECRET_NAME:-mail-secret}"
  K8S_MAIL_CONFIGMAP_NAME="${K8S_MAIL_CONFIGMAP_NAME:-mail-config}"
}

detect_tools() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found."
}

validate_target() {
  [[ -n "${K8S_DEPLOYMENT}" ]] || die "K8S_DEPLOYMENT is required."
  kubectl -n "${K8S_NAMESPACE}" get deployment "${K8S_DEPLOYMENT}" >/dev/null 2>&1 || \
    die "Deployment ${K8S_DEPLOYMENT} was not found in namespace ${K8S_NAMESPACE}."
}

apply_secret() {
  kubectl -n "${K8S_NAMESPACE}" create secret generic "${K8S_MAIL_SECRET_NAME}" \
    "--from-literal=MAIL_USERNAME=${MAIL_USERNAME}" \
    "--from-literal=MAIL_PASSWORD=${MAIL_PASSWORD}" \
    --dry-run=client -o yaml | kubectl -n "${K8S_NAMESPACE}" apply -f - >/dev/null
}

apply_configmap() {
  kubectl -n "${K8S_NAMESPACE}" create configmap "${K8S_MAIL_CONFIGMAP_NAME}" \
    "--from-literal=MAIL_HOST=${MAIL_HOST}" \
    "--from-literal=MAIL_PORT=${MAIL_PORT}" \
    "--from-literal=APP_CONTACT_MAIL_FROM=${APP_CONTACT_MAIL_FROM}" \
    --dry-run=client -o yaml | kubectl -n "${K8S_NAMESPACE}" apply -f - >/dev/null
}

update_deployment() {
  kubectl -n "${K8S_NAMESPACE}" set env "deployment/${K8S_DEPLOYMENT}" \
    --from="configmap/${K8S_MAIL_CONFIGMAP_NAME}" \
    --from="secret/${K8S_MAIL_SECRET_NAME}" >/dev/null

  # Force new pods so the refreshed Secret/ConfigMap values are picked up.
  kubectl -n "${K8S_NAMESPACE}" rollout restart "deployment/${K8S_DEPLOYMENT}" >/dev/null
  kubectl -n "${K8S_NAMESPACE}" rollout status "deployment/${K8S_DEPLOYMENT}" --timeout=180s
}

write_status() {
  mkdir -p "${ARTIFACTS_DIR}"
  cat > "${STATUS_FILE}" <<EOF
ACTION=apply
K8S_NAMESPACE=${K8S_NAMESPACE}
K8S_DEPLOYMENT=${K8S_DEPLOYMENT}
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
