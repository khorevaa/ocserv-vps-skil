#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage: remote-status.sh [--config <path>]
EOF
}

CONFIG="/etc/ocserv/ocserv.conf"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
validate_config_path "${CONFIG}"
require_command systemctl
require_command ss

printf '%s\n' '=== Managed service ==='
if service_exists "${OCSERV_SERVICE}"; then
  printf 'Unit: %s\n' "${OCSERV_SERVICE}"
  printf 'Active: %s\n' "$(bool_service_active "${OCSERV_SERVICE}")"
  printf 'Enabled: %s\n' "$(bool_service_enabled "${OCSERV_SERVICE}")"
  main_pid="$(systemctl show --property MainPID --value "${OCSERV_SERVICE}" 2>/dev/null || true)"
  printf 'Main PID: %s\n' "${main_pid:-none}"
  if [[ "${main_pid}" =~ ^[1-9][0-9]*$ && -e "/proc/${main_pid}/exe" ]]; then
    printf 'Running executable: %s\n' "$(readlink -f "/proc/${main_pid}/exe" 2>/dev/null || true)"
  fi
else
  printf '%s\n' 'Managed unit is not installed.'
fi

printf '\n%s\n' '=== Release links and versions ==='
current_target="$(readlink -f "${OCSERV_CURRENT_LINK}" 2>/dev/null || true)"
printf 'Current target: %s\n' "${current_target:-none}"
if [[ -n "${current_target}" ]]; then
  binary="$(find_release_ocserv "${current_target}" 2>/dev/null || true)"
  if [[ -n "${binary}" ]]; then
    printf 'Current binary: %s\n' "${binary}"
    printf 'Current version output: %s\n' "$(binary_version_line "${binary}" || true)"
    if [[ -r "${CONFIG}" ]]; then
      status_config_output=''
      if status_config_output="$(test_ocserv_config "${binary}" "${CONFIG}" 2>&1)"; then
        printf '%s\n' 'Config validation: passed'
      else
        printf '%s\n' 'Config validation: FAILED'
        printf '%s\n' "${status_config_output}" | sed -n '1,80p'
      fi
    fi
  else
    printf '%s\n' 'Current target has no ocserv binary.'
  fi
fi

printf 'Retained releases:\n'
if [[ -d "${OCSERV_RELEASES_DIR}" ]]; then
  find "${OCSERV_RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' | sort -V
else
  printf '%s\n' '  none'
fi

printf '\n%s\n' '=== Listeners and control status ==='
if [[ -r "${CONFIG}" ]]; then
  print_listener_summary "${CONFIG}"
else
  printf 'Config is not readable: %s\n' "${CONFIG}"
fi
if [[ -n "${current_target}" ]]; then
  occtl="$(find_release_occtl "${current_target}" 2>/dev/null || true)"
  if [[ -n "${occtl}" ]]; then
    run_bounded "${occtl}" show status 2>/dev/null | sed -n '1,40p' || printf '%s\n' 'occtl status unavailable.'
  fi
fi

printf '\n%s\n' '=== State ==='
if [[ -f "${OCSERV_STATE_FILE}" ]]; then
  sed -n '1,80p' "${OCSERV_STATE_FILE}"
else
  printf '%s\n' 'No managed state file.'
fi

printf '\n%s\n' '=== Backups ==='
if [[ -d "${OCSERV_BACKUP_ROOT}" ]]; then
  find "${OCSERV_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' | sort -r | sed -n '1,10p'
else
  printf '%s\n' '  none'
fi

printf '\n%s\n' '=== Legacy service ==='
legacy_service="$(state_get legacy_service || true)"
if [[ -n "${legacy_service}" ]]; then
  printf 'Recorded legacy service: %s\n' "${legacy_service}"
  printf 'Current active=%s enabled=%s\n' "$(bool_service_active "${legacy_service}")" "$(bool_service_enabled "${legacy_service}")"
else
  printf '%s\n' 'No legacy service recorded.'
fi
