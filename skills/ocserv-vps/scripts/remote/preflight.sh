#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage: remote-preflight.sh [--config <path>] [--target-version <version>]
EOF
}

CONFIG="/etc/ocserv/ocserv.conf"
TARGET_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    --target-version) TARGET_VERSION="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
validate_config_path "${CONFIG}"
[[ -z "${TARGET_VERSION}" ]] || validate_version "${TARGET_VERSION}"
require_command systemctl
require_command ss
require_command awk
require_command df

if [[ ! -r /etc/os-release ]]; then
  die '/etc/os-release is unavailable.'
fi
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) die "Unsupported distribution: ${ID:-unknown}. Expected Debian or Ubuntu." ;;
esac

printf '%s\n' '=== Host ==='
printf 'Hostname: %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'OS: %s\n' "${PRETTY_NAME:-${ID:-unknown}}"
printf 'Kernel: %s\n' "$(uname -srmo)"
printf 'Architecture: %s\n' "$(dpkg --print-architecture 2>/dev/null || uname -m)"
printf 'Free space under /opt: '
df -hP /opt 2>/dev/null | awk 'NR == 2 {print $4 " available of " $2}' || df -hP / | awk 'NR == 2 {print $4 " available of " $2}'
printf 'Memory: '
awk '/MemTotal/ {total=$2} /MemAvailable/ {available=$2} END {printf "%.1f GiB available of %.1f GiB\n", available/1048576, total/1048576}' /proc/meminfo

printf '\n%s\n' '=== Configuration ==='
printf 'Config path: %s\n' "${CONFIG}"
if [[ -r "${CONFIG}" ]]; then
  printf '%s\n' 'Readable: yes'
  for directive in server-cert server-key; do
    value="$(config_value "${CONFIG}" "${directive}" || true)"
    if [[ -n "${value}" ]]; then
      if [[ "${value}" == /* ]]; then
        if [[ -e "${value}" ]]; then
          printf '%s: present\n' "${directive}"
        else
          printf '%s: referenced path is missing (%s)\n' "${directive}" "${value}"
        fi
      else
        printf '%s: non-file or relative reference (%s)\n' "${directive}" "${value}"
      fi
    else
      printf '%s: not found in config\n' "${directive}"
    fi
  done
  print_listener_summary "${CONFIG}"
else
  printf '%s\n' 'Readable: no (deployment blocker)'
fi

printf '\n%s\n' '=== Services ==='
for unit in "${OCSERV_SERVICE}" ocserv.service ocserv.socket; do
  if service_exists "${unit}"; then
    printf '%s: load=present active=%s enabled=%s\n' \
      "${unit}" "$(bool_service_active "${unit}")" "$(bool_service_enabled "${unit}")"
  else
    printf '%s: not found\n' "${unit}"
  fi
done
if service_exists ocserv.socket && service_active ocserv.socket; then
  warn 'ocserv.socket is active. Socket-activated deployments are intentionally unsupported.'
fi

printf '\n%s\n' '=== Current release ==='
current_target="$(readlink -f "${OCSERV_CURRENT_LINK}" 2>/dev/null || true)"
printf 'Current symlink target: %s\n' "${current_target:-none}"
current_binary=""
if [[ -n "${current_target}" ]]; then
  current_binary="$(find_release_ocserv "${current_target}" 2>/dev/null || true)"
fi
if [[ -z "${current_binary}" ]]; then
  current_binary="$(command -v ocserv 2>/dev/null || true)"
fi
if [[ -n "${current_binary}" ]]; then
  printf 'Detected binary: %s\n' "${current_binary}"
  printf 'Version: %s\n' "$(binary_version_line "${current_binary}" || true)"
  if [[ -r "${CONFIG}" ]]; then
    preflight_config_output=''
    if preflight_config_output="$(test_ocserv_config "${current_binary}" "${CONFIG}" 2>&1)"; then
      printf '%s\n' 'Config validation with current binary: passed'
    else
      printf '%s\n' 'Config validation with current binary: FAILED'
      printf '%s\n' "${preflight_config_output}" | sed -n '1,80p'
    fi
  fi
else
  printf '%s\n' 'Detected binary: none'
fi

printf '\n%s\n' '=== Active sessions ==='
occtl_binary=""
if [[ -n "${current_target}" ]]; then
  occtl_binary="$(find_release_occtl "${current_target}" 2>/dev/null || true)"
fi
[[ -n "${occtl_binary}" ]] || occtl_binary="$(command -v occtl 2>/dev/null || true)"
if [[ -n "${occtl_binary}" ]]; then
  run_bounded "${occtl_binary}" show status 2>/dev/null | sed -n '1,40p' || printf '%s\n' 'occtl status unavailable.'
  run_bounded "${occtl_binary}" show users 2>/dev/null | sed -n '1,80p' || true
else
  printf '%s\n' 'occtl not found.'
fi

printf '\n%s\n' '=== Target path ==='
if [[ -n "${TARGET_VERSION}" ]]; then
  target="${OCSERV_RELEASES_DIR}/${TARGET_VERSION}"
  if [[ -e "${target}" ]]; then
    printf 'Target release path already exists: %s (deployment blocker)\n' "${target}"
  else
    printf 'Target release path is free: %s\n' "${target}"
  fi
else
  printf '%s\n' 'No target version supplied.'
fi

printf '\n%s\n' '=== Tooling ==='
for command in apt-get curl gpg tar python3 systemctl ss flock; do
  if command -v "${command}" >/dev/null 2>&1; then
    printf '%s: present\n' "${command}"
  else
    printf '%s: missing\n' "${command}"
  fi
done

printf '\n%s\n' 'Preflight is read-only. Deployment still requires explicit artifact pins and --approve-restart.'
