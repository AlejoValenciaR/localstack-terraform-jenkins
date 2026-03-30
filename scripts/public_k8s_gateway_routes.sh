#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${PROJECT_ROOT}/artifacts"
ENV_FILE="${PROJECT_ROOT}/config/public-gateway.env"
DEFAULT_ROUTES_FILE="${PROJECT_ROOT}/config/public-k8s-routes.txt"
STATUS_FILE="${ARTIFACTS_DIR}/public-gateway-routes.txt"
TMP_INCLUDE_FILE=""
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
  bash scripts/public_k8s_gateway_routes.sh apply

Optional defaults file:
  config/public-gateway.env

Required access variables when PUBLIC_GATEWAY_ACCESS_MODE=ssh:
  PUBLIC_GATEWAY_REMOTE_HOST
  PUBLIC_GATEWAY_REMOTE_USER
  SSH_KEY_FILE

Optional variables:
  PUBLIC_GATEWAY_ACCESS_MODE (default: ssh; supported: local, ssh)
  PUBLIC_GATEWAY_REMOTE_PORT (default: 22)
  PUBLIC_GATEWAY_SERVER_NAME (default: nauthappstest.tech)
  PUBLIC_GATEWAY_SITE_CONFIG (default: auto-detect first nginx site file containing the server_name)
  PUBLIC_GATEWAY_INCLUDE_DIR (default: /etc/nginx/nauthapps.d)
  PUBLIC_GATEWAY_INCLUDE_FILE (default: /etc/nginx/nauthapps.d/public-k8s-routes.conf)
  PUBLIC_K8S_UPSTREAM (default: http://127.0.0.1:8081)
  PUBLIC_K8S_ROUTES_FILE (default: config/public-k8s-routes.txt)
EOF
}

trim_line() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
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
  PUBLIC_GATEWAY_ACCESS_MODE="${PUBLIC_GATEWAY_ACCESS_MODE:-ssh}"
  PUBLIC_GATEWAY_SERVER_NAME="${PUBLIC_GATEWAY_SERVER_NAME:-nauthappstest.tech}"
  PUBLIC_GATEWAY_REMOTE_HOST="${PUBLIC_GATEWAY_REMOTE_HOST:-${K8S_REMOTE_HOST:-}}"
  PUBLIC_GATEWAY_REMOTE_PORT="${PUBLIC_GATEWAY_REMOTE_PORT:-${K8S_REMOTE_PORT:-22}}"
  PUBLIC_GATEWAY_REMOTE_USER="${PUBLIC_GATEWAY_REMOTE_USER:-${SSH_USERNAME:-}}"
  PUBLIC_GATEWAY_SITE_CONFIG="${PUBLIC_GATEWAY_SITE_CONFIG:-}"
  PUBLIC_GATEWAY_INCLUDE_DIR="${PUBLIC_GATEWAY_INCLUDE_DIR:-/etc/nginx/nauthapps.d}"
  PUBLIC_GATEWAY_INCLUDE_FILE="${PUBLIC_GATEWAY_INCLUDE_FILE:-${PUBLIC_GATEWAY_INCLUDE_DIR}/public-k8s-routes.conf}"
  PUBLIC_K8S_UPSTREAM="${PUBLIC_K8S_UPSTREAM:-http://127.0.0.1:8081}"
  PUBLIC_K8S_ROUTES_FILE="${PUBLIC_K8S_ROUTES_FILE:-${DEFAULT_ROUTES_FILE}}"
}

detect_tools() {
  case "${PUBLIC_GATEWAY_ACCESS_MODE}" in
    local)
      command -v nginx >/dev/null 2>&1 || die "nginx not found."
      command -v sudo >/dev/null 2>&1 || die "sudo not found."
      ;;
    ssh)
      command -v ssh >/dev/null 2>&1 || die "ssh not found."
      command -v sed >/dev/null 2>&1 || die "sed not found."
      ;;
    *)
      die "Unsupported PUBLIC_GATEWAY_ACCESS_MODE: ${PUBLIC_GATEWAY_ACCESS_MODE}"
      ;;
  esac
}

prepare_ssh() {
  [[ "${PUBLIC_GATEWAY_ACCESS_MODE}" == "ssh" ]] || return 0
  [[ -n "${PUBLIC_GATEWAY_REMOTE_HOST}" ]] || die "PUBLIC_GATEWAY_REMOTE_HOST is required when PUBLIC_GATEWAY_ACCESS_MODE=ssh."
  [[ -n "${PUBLIC_GATEWAY_REMOTE_USER}" ]] || die "PUBLIC_GATEWAY_REMOTE_USER is required when PUBLIC_GATEWAY_ACCESS_MODE=ssh."
  [[ -n "${SSH_KEY_FILE:-}" ]] || die "SSH_KEY_FILE is required when PUBLIC_GATEWAY_ACCESS_MODE=ssh."

  SSH_ARGS=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -p "${PUBLIC_GATEWAY_REMOTE_PORT}"
    -i "${SSH_KEY_FILE}"
  )
}

ssh_target() {
  printf '%s@%s' "${PUBLIC_GATEWAY_REMOTE_USER}" "${PUBLIC_GATEWAY_REMOTE_HOST}"
}

run_remote_shell() {
  local command="$1"

  case "${PUBLIC_GATEWAY_ACCESS_MODE}" in
    local)
      bash -lc "${command}"
      ;;
    ssh)
      ssh "${SSH_ARGS[@]}" "$(ssh_target)" "bash -lc $(printf '%q' "${command}")"
      ;;
  esac
}

check_connectivity() {
  [[ "${PUBLIC_GATEWAY_ACCESS_MODE}" == "ssh" ]] || return 0
  if ! run_remote_shell true >/dev/null 2>&1; then
    die "SSH connection to ${PUBLIC_GATEWAY_REMOTE_HOST} failed."
  fi
}

load_routes() {
  [[ -f "${PUBLIC_K8S_ROUTES_FILE}" ]] || die "Route list file not found: ${PUBLIC_K8S_ROUTES_FILE}"

  declare -g -a PUBLIC_ROUTES=()
  declare -A seen=()
  local line=""
  local route=""

  while IFS= read -r line; do
    route="$(trim_line "${line}")"
    [[ -n "${route}" ]] || continue
    [[ "${route}" != \#* ]] || continue

    if [[ "${route}" != /* ]]; then
      die "Route must start with '/': ${route}"
    fi

    if [[ "${route}" == "/" ]]; then
      die "Route '/' is not allowed here because the nginx hub keeps the root path."
    fi

    route="${route%/}"
    [[ -n "${route}" ]] || die "A route normalized to an empty value."

    if [[ -n "${seen[${route}]:-}" ]]; then
      continue
    fi

    seen["${route}"]=1
    PUBLIC_ROUTES+=("${route}")
  done < "${PUBLIC_K8S_ROUTES_FILE}"

  [[ "${#PUBLIC_ROUTES[@]}" -gt 0 ]] || die "No public routes were loaded from ${PUBLIC_K8S_ROUTES_FILE}."
}

write_local_include_file() {
  TMP_INCLUDE_FILE="$(mktemp)"

  {
    echo "# Managed by scripts/public_k8s_gateway_routes.sh"
    echo "# Public server_name: ${PUBLIC_GATEWAY_SERVER_NAME}"
    echo "# Upstream ingress listener: ${PUBLIC_K8S_UPSTREAM}"
    echo

    for route in "${PUBLIC_ROUTES[@]}"; do
      cat <<EOF
location = ${route} {
  proxy_http_version 1.1;
  proxy_set_header Host \$host;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_redirect off;
  proxy_pass ${PUBLIC_K8S_UPSTREAM};
}

location ^~ ${route}/ {
  proxy_http_version 1.1;
  proxy_set_header Host \$host;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_redirect off;
  proxy_pass ${PUBLIC_K8S_UPSTREAM};
}

EOF
    done
  } > "${TMP_INCLUDE_FILE}"
}

detect_site_config() {
  if [[ -n "${PUBLIC_GATEWAY_SITE_CONFIG}" ]]; then
    run_remote_shell "test -f $(printf '%q' "${PUBLIC_GATEWAY_SITE_CONFIG}")" || \
      die "PUBLIC_GATEWAY_SITE_CONFIG was set but the file was not found: ${PUBLIC_GATEWAY_SITE_CONFIG}"
    return
  fi

  PUBLIC_GATEWAY_SITE_CONFIG="$(
    run_remote_shell "grep -Rls $(printf '%q' "${PUBLIC_GATEWAY_SERVER_NAME}") /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/nginx/sites-available 2>/dev/null | head -n 1"
  )"
  [[ -n "${PUBLIC_GATEWAY_SITE_CONFIG}" ]] || \
    die "Could not auto-detect an nginx site config for server_name ${PUBLIC_GATEWAY_SERVER_NAME}. Set PUBLIC_GATEWAY_SITE_CONFIG explicitly."

  log "Detected nginx site config: ${PUBLIC_GATEWAY_SITE_CONFIG}"
}

upload_include_file() {
  local include_dir_q
  local include_file_q
  include_dir_q="$(printf '%q' "${PUBLIC_GATEWAY_INCLUDE_DIR}")"
  include_file_q="$(printf '%q' "${PUBLIC_GATEWAY_INCLUDE_FILE}")"

  run_remote_shell "sudo install -d -m 755 ${include_dir_q}"

  case "${PUBLIC_GATEWAY_ACCESS_MODE}" in
    local)
      sudo tee "${PUBLIC_GATEWAY_INCLUDE_FILE}" >/dev/null < "${TMP_INCLUDE_FILE}"
      ;;
    ssh)
      ssh "${SSH_ARGS[@]}" "$(ssh_target)" "sudo tee ${include_file_q} >/dev/null" < "${TMP_INCLUDE_FILE}"
      ;;
  esac
}

ensure_include_directive() {
  local include_directive="include ${PUBLIC_GATEWAY_INCLUDE_DIR}/*.conf;"
  local include_line="    ${include_directive}"
  local site_config_q
  local target_server_name_q
  local include_directive_q
  local include_line_q
  local awk_program
  local awk_program_q

  site_config_q="$(printf '%q' "${PUBLIC_GATEWAY_SITE_CONFIG}")"
  target_server_name_q="$(printf '%q' "${PUBLIC_GATEWAY_SERVER_NAME}")"
  include_directive_q="$(printf '%q' "${include_directive}")"
  include_line_q="$(printf '%q' "${include_line}")"
  awk_program="$(cat <<'AWK'
function strip_comment(line,    clean) {
  clean = line
  sub(/[[:space:]]*#.*/, "", clean)
  return clean
}

function trim(line,    clean) {
  clean = line
  sub(/^[[:space:]]+/, "", clean)
  sub(/[[:space:]]+$/, "", clean)
  return clean
}

function brace_delta(line,    clean, open_count, close_count) {
  clean = strip_comment(line)
  open_count = gsub(/\{/, "{", clean)
  close_count = gsub(/\}/, "}", clean)
  return open_count - close_count
}

function line_has_include(line, include_directive,    clean) {
  clean = trim(strip_comment(line))
  return clean == include_directive
}

function line_has_server_name(line, target_server_name,    clean, count, names, i) {
  clean = strip_comment(line)
  if (clean !~ /^[[:space:]]*server_name[[:space:]]+/) {
    return 0
  }

  sub(/^[[:space:]]*server_name[[:space:]]+/, "", clean)
  sub(/[[:space:]]*;[[:space:]]*$/, "", clean)
  count = split(clean, names, /[[:space:]]+/)

  for (i = 1; i <= count; i++) {
    if (names[i] == target_server_name) {
      return 1
    }
  }

  return 0
}

function line_is_tls_listen(line,    clean) {
  clean = strip_comment(line)
  if (clean !~ /^[[:space:]]*listen[[:space:]]+/) {
    return 0
  }

  if (clean ~ /(^|[[:space:]:])443([[:space:];]|$)/) {
    return 1
  }

  if (clean ~ /(^|[[:space:]])ssl([[:space:];]|$)/) {
    return 1
  }

  return 0
}

{
  lines[NR] = $0

  if (!in_server && depth == 0 && strip_comment($0) ~ /^[[:space:]]*server[[:space:]]*\{[[:space:]]*$/) {
    in_server = 1
    block_count++
    block_matches_name[block_count] = 0
    block_is_tls[block_count] = 0
    block_has_include[block_count] = 0
    block_end[block_count] = 0
  }

  if (in_server) {
    if (line_has_server_name($0, target_server_name)) {
      block_matches_name[block_count] = 1
    }

    if (line_is_tls_listen($0)) {
      block_is_tls[block_count] = 1
    }

    if (line_has_include($0, include_directive)) {
      block_has_include[block_count] = 1
    }
  }

  depth += brace_delta($0)

  if (depth < 0) {
    print "Nginx config parsing failed: brace depth became negative near line " NR "." > "/dev/stderr"
    exit 20
  }

  if (in_server && depth == 0) {
    block_end[block_count] = NR
    in_server = 0
  }
}

END {
  if (depth != 0) {
    print "Nginx config parsing failed: unbalanced braces in " FILENAME "." > "/dev/stderr"
    exit 21
  }

  match_count = 0
  tls_match_count = 0
  include_match_count = 0
  include_match_block = 0

  for (i = 1; i <= block_count; i++) {
    if (!block_matches_name[i]) {
      continue
    }

    matches[++match_count] = i

    if (block_is_tls[i]) {
      tls_matches[++tls_match_count] = i
    }

    if (block_has_include[i]) {
      include_match_count++
      include_match_block = i
    }
  }

  if (match_count == 0) {
    print "Could not find a server block with server_name " target_server_name " in " FILENAME "." > "/dev/stderr"
    exit 22
  }

  if (tls_match_count == 1) {
    target_block = tls_matches[1]
  } else if (match_count == 1) {
    target_block = matches[1]
  } else if (include_match_count == 1) {
    target_block = include_match_block
  } else {
    print "Cannot safely inject the include into " FILENAME " because " match_count " server blocks match server_name " target_server_name "." > "/dev/stderr"
    print "Set PUBLIC_GATEWAY_SITE_CONFIG to a dedicated single-site file, or add this line manually inside the intended server block:" > "/dev/stderr"
    print include_line > "/dev/stderr"
    exit 23
  }

  if (block_has_include[target_block]) {
    for (i = 1; i <= NR; i++) {
      print lines[i]
    }
    exit 0
  }

  if (block_end[target_block] == 0) {
    print "Could not determine where the matching server block ends in " FILENAME "." > "/dev/stderr"
    exit 24
  }

  for (i = 1; i <= NR; i++) {
    if (i == block_end[target_block]) {
      print include_line
    }
    print lines[i]
  }
}
AWK
)"
  awk_program_q="$(printf '%q' "${awk_program}")"

  run_remote_shell "
    site_config=${site_config_q}
    target_server_name=${target_server_name_q}
    include_directive=${include_directive_q}
    include_line=${include_line_q}
    awk_program=${awk_program_q}
    awk_output=\$(mktemp)
    tmp_file=\"\${site_config}.tmp.codex\"
    backup_file=\"\${site_config}.bak.codex\"
    printf '%s\n' \"\${awk_program}\" | awk \
      -v target_server_name=\"\${target_server_name}\" \
      -v include_directive=\"\${include_directive}\" \
      -v include_line=\"\${include_line}\" \
      -f - \"\${site_config}\" > \"\${awk_output}\"

    if cmp -s \"\${awk_output}\" \"\${site_config}\"; then
      rm -f \"\${awk_output}\"
      exit 0
    fi

    sudo cp \"\${site_config}\" \"\${backup_file}\"
    sudo tee \"\${tmp_file}\" >/dev/null < \"\${awk_output}\"
    sudo mv \"\${tmp_file}\" \"\${site_config}\"
    rm -f \"\${awk_output}\"
  "
}

test_and_reload_nginx() {
  run_remote_shell '
    sudo nginx -t
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl reload nginx
    else
      sudo service nginx reload
    fi
  '
}

write_status() {
  mkdir -p "${ARTIFACTS_DIR}"
  {
    echo "ACTION=apply"
    echo "PUBLIC_GATEWAY_ACCESS_MODE=${PUBLIC_GATEWAY_ACCESS_MODE}"
    echo "PUBLIC_GATEWAY_REMOTE_HOST=${PUBLIC_GATEWAY_REMOTE_HOST}"
    echo "PUBLIC_GATEWAY_SERVER_NAME=${PUBLIC_GATEWAY_SERVER_NAME}"
    echo "PUBLIC_GATEWAY_SITE_CONFIG=${PUBLIC_GATEWAY_SITE_CONFIG}"
    echo "PUBLIC_GATEWAY_INCLUDE_FILE=${PUBLIC_GATEWAY_INCLUDE_FILE}"
    echo "PUBLIC_K8S_UPSTREAM=${PUBLIC_K8S_UPSTREAM}"
    echo "PUBLIC_K8S_ROUTES_FILE=${PUBLIC_K8S_ROUTES_FILE}"
    printf 'PUBLIC_ROUTES='
    printf '%s' "${PUBLIC_ROUTES[*]}" | sed 's/ /,/g'
    printf '\n'
  } > "${STATUS_FILE}"

  log "Public gateway route sync summary written to ${STATUS_FILE}"
}

cleanup() {
  if [[ -n "${TMP_INCLUDE_FILE}" && -f "${TMP_INCLUDE_FILE}" ]]; then
    rm -f "${TMP_INCLUDE_FILE}"
  fi
}

run_apply() {
  detect_tools
  prepare_ssh
  check_connectivity
  load_routes
  write_local_include_file
  detect_site_config
  upload_include_file
  ensure_include_directive
  test_and_reload_nginx
  write_status
  log "Public nginx gateway route sync completed."
}

main() {
  local action="${1:-}"
  trap cleanup EXIT

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
