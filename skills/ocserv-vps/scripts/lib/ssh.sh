#!/usr/bin/env bash
set -euo pipefail

OCSERV_LOCAL_LIB_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OCSERV_SCRIPTS_DIR="$(CDPATH= cd -- "${OCSERV_LOCAL_LIB_DIR}/.." && pwd)"

ocserv_require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "${value}" ]]; then
    printf '%s requires a value.\n' "${option}" >&2
    exit 2
  fi
}

ocserv_validate_port() {
  local label="$1"
  local port="$2"
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    printf 'Invalid %s: %s\n' "${label}" "${port}" >&2
    exit 2
  fi
}

ocserv_validate_version() {
  local version="$1"
  if [[ ! "${version}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]]; then
    printf 'Unsafe version value: %s\n' "${version}" >&2
    exit 2
  fi
}

ocserv_validate_domain() {
  local domain="$1"
  if [[ ! "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || [[ "${domain}" != *.* ]]; then
    printf 'Invalid public domain: %s\n' "${domain}" >&2
    exit 2
  fi
}

ocserv_validate_registry_image() {
  local image="$1"
  if [[ ! "${image}" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[0-9A-Fa-f]{64}$ ]]; then
    printf '%s\n' '--image must be ghcr.io/<owner>/<image>[:tag]@sha256:<64-hex>.' >&2
    exit 2
  fi
}

ocserv_validate_cidr() {
  local cidr="$1"
  if [[ ! "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([8-9]|[12][0-9]|3[0-2])$ ]]; then
    printf 'Invalid IPv4 CIDR: %s\n' "${cidr}" >&2
    exit 2
  fi
}

ocserv_run_remote() {
  local remote_script="$1"
  local host="$2"
  local ssh_password="$3"
  local ssh_port="$4"
  local identity_file="$5"
  local accept_new_host_key="$6"
  shift 6

  if [[ -z "${host}" ]]; then
    printf '%s\n' '--host is required.' >&2
    exit 2
  fi
  if [[ ! -r "${remote_script}" ]]; then
    printf 'Remote script is not readable: %s\n' "${remote_script}" >&2
    exit 2
  fi

  local common_script="${OCSERV_SCRIPTS_DIR}/remote/common.sh"
  if [[ ! -r "${common_script}" ]]; then
    printf 'Remote common library is not readable: %s\n' "${common_script}" >&2
    exit 2
  fi

  local remote_args=""
  local arg quoted
  for arg in "$@"; do
    printf -v quoted '%q' "${arg}"
    remote_args+=" ${quoted}"
  done

  local remote_command="bash -s --${remote_args}"
  local -a ssh_args=(
    -T
    -p "${ssh_port}"
    -o ConnectTimeout=15
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
  )

  if [[ -n "${identity_file}" ]]; then
    ssh_args+=( -i "${identity_file}" -o IdentitiesOnly=yes )
  fi
  if [[ "${accept_new_host_key}" == "1" ]]; then
    ssh_args+=( -o StrictHostKeyChecking=accept-new )
  fi
  if [[ -z "${ssh_password}" ]]; then
    ssh_args+=( -o BatchMode=yes )
  fi

  local -a runner=(bash "${OCSERV_SCRIPTS_DIR}/ssh-with-password.sh")
  if [[ -n "${ssh_password}" ]]; then
    runner+=(--ssh-password "${ssh_password}")
  fi

  {
    cat "${common_script}"
    printf '\n'
    cat "${remote_script}"
  } | "${runner[@]}" "${ssh_args[@]}" "${host}" "${remote_command}"
}
