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

ocserv_validate_ssh_port() {
  local port="$1"
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    printf 'Invalid SSH port: %s\n' "${port}" >&2
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
