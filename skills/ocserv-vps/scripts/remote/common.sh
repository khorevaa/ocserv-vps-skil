#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 027

OCSERV_ROOT="/opt/ocserv"
OCSERV_RELEASES_DIR="${OCSERV_ROOT}/releases"
OCSERV_CURRENT_LINK="${OCSERV_ROOT}/current"
OCSERV_STATE_DIR="/var/lib/ocserv-release"
OCSERV_STATE_FILE="${OCSERV_STATE_DIR}/state"
OCSERV_BACKUP_ROOT="/var/backups/ocserv-release"
OCSERV_SERVICE="ocserv-release.service"
OCSERV_UNIT="/etc/systemd/system/${OCSERV_SERVICE}"
OCSERV_LOCK="/run/lock/ocserv-release.lock"

info() {
  printf '[ocserv-release] %s\n' "$*"
}

warn() {
  printf '[ocserv-release] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[ocserv-release] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die 'Run the remote script as root.'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_version() {
  [[ "$1" =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] || die "Unsafe version value: $1"
}

validate_sha256() {
  [[ "$1" =~ ^[0-9A-Fa-f]{64}$ ]] || die 'SHA-256 must contain exactly 64 hexadecimal characters.'
}

validate_https_url() {
  local label="$1"
  local value="$2"
  [[ "${value}" == https://* ]] || die "${label} must use HTTPS."
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* && "${value}" != *[[:space:]]* ]] || die "${label} contains whitespace."
}

validate_config_path() {
  local value="$1"
  [[ "${value}" == /* ]] || die 'Config path must be absolute.'
  [[ "${value}" =~ ^/[0-9A-Za-z_./-]+$ ]] || die "Unsafe config path: ${value}"
}

config_backup_scope() {
  local config="$1"
  if [[ "${config}" == /etc/ocserv/* ]]; then
    printf '%s\n' '/etc/ocserv'
  else
    printf '%s\n' "${config}"
  fi
}

validate_service_name() {
  [[ "$1" =~ ^[0-9A-Za-z_.@-]+\.service$ ]] || die "Unsafe systemd service name: $1"
}

normalize_fingerprint() {
  printf '%s' "$1" | tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]'
}

service_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

service_active() {
  systemctl is-active --quiet "$1"
}

service_enabled() {
  systemctl is-enabled --quiet "$1"
}

bool_service_active() {
  if service_exists "$1" && service_active "$1"; then printf '1'; else printf '0'; fi
}

bool_service_enabled() {
  if service_exists "$1" && service_enabled "$1"; then printf '1'; else printf '0'; fi
}

config_value() {
  local config="$1"
  local wanted="$2"
  awk -v wanted="${wanted}" '
    /^[[:space:]]*#/ { next }
    {
      line=$0
      eq=index(line, "=")
      if (eq == 0) next
      key=substr(line, 1, eq-1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != wanted) next
      value=substr(line, eq+1)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value=substr(value, 2, length(value)-2)
      }
      result=value
    }
    END { if (result != "") print result }
  ' "${config}"
}

find_release_ocserv() {
  local release="$1"
  local candidate
  for candidate in \
    "${release}/sbin/ocserv" \
    "${release}/usr/sbin/ocserv" \
    "${release}/bin/ocserv"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

find_release_occtl() {
  local release="$1"
  local candidate
  for candidate in \
    "${release}/bin/occtl" \
    "${release}/usr/bin/occtl" \
    "${release}/sbin/occtl"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

binary_version_line() {
  local binary="$1"
  "${binary}" --version 2>&1 | sed -n '1p'
}

run_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 5s "$@"
  else
    "$@"
  fi
}

test_ocserv_config() {
  local binary="$1"
  local config="$2"
  local help_text
  help_text="$("${binary}" --help 2>&1 || true)"
  if grep -q -- '--test-config' <<<"${help_text}"; then
    (cd / && "${binary}" --test-config --config="${config}")
    return
  fi
  if grep -Eq '(^|[[:space:],])-t([[:space:],]|$)' <<<"${help_text}"; then
    (cd / && "${binary}" -t -c "${config}")
    return
  fi
  printf 'The binary %s does not advertise a config-test option. Extend the skill before activation.\n' "${binary}" >&2
  return 2
}

listener_exists() {
  local protocol="$1"
  local port="$2"
  local ss_flag
  case "${protocol}" in
    tcp) ss_flag='-ltn' ;;
    udp) ss_flag='-lun' ;;
    *) return 2 ;;
  esac
  ss -H "${ss_flag}" | awk -v wanted="${port}" '
    {
      endpoint=$4
      gsub(/\[/, "", endpoint)
      gsub(/\]/, "", endpoint)
      count=split(endpoint, parts, ":")
      if (parts[count] == wanted) found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

configured_tcp_port() {
  local config="$1"
  local port
  port="$(config_value "${config}" tcp-port || true)"
  [[ -n "${port}" ]] || port='443'
  printf '%s\n' "${port}"
}

configured_udp_port() {
  local config="$1"
  local port
  port="$(config_value "${config}" udp-port || true)"
  if [[ -z "${port}" ]]; then
    port="$(configured_tcp_port "${config}")"
  fi
  printf '%s\n' "${port}"
}

state_get() {
  local key="$1"
  [[ -f "${OCSERV_STATE_FILE}" ]] || return 0
  awk -F= -v wanted="${key}" '$1 == wanted { value=substr($0, index($0, "=")+1) } END { print value }' "${OCSERV_STATE_FILE}"
}

write_state() {
  local current_version="$1"
  local previous_version="$2"
  local legacy_service="$3"
  local legacy_was_active="$4"
  local legacy_was_enabled="$5"
  local last_backup="$6"
  local temp
  install -d -m 0750 "${OCSERV_STATE_DIR}"
  temp="$(mktemp "${OCSERV_STATE_DIR}/state.XXXXXX")"
  cat > "${temp}" <<EOF
current_version=${current_version}
previous_version=${previous_version}
legacy_service=${legacy_service}
legacy_was_active=${legacy_was_active}
legacy_was_enabled=${legacy_was_enabled}
last_backup=${last_backup}
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 0640 "${temp}"
  mv -f "${temp}" "${OCSERV_STATE_FILE}"
}

version_from_release_path() {
  local path="$1"
  if [[ "${path}" == "${OCSERV_RELEASES_DIR}/"* ]]; then
    basename "${path}"
  fi
}

atomic_current_link() {
  local release="$1"
  install -d -m 0755 "${OCSERV_ROOT}"
  local temp="${OCSERV_ROOT}/.current.$$.new"
  ln -s "${release}" "${temp}"
  mv -Tf "${temp}" "${OCSERV_CURRENT_LINK}"
}

health_check_release() {
  local service="$1"
  local expected_binary="$2"
  local config="$3"
  local timeout_seconds="$4"
  local tcp_port udp_port deadline pid actual_binary

  tcp_port="$(configured_tcp_port "${config}")"
  udp_port="$(configured_udp_port "${config}")"
  [[ "${tcp_port}" =~ ^[0-9]+$ ]] || die "Invalid tcp-port in ${config}: ${tcp_port}"
  [[ "${udp_port}" =~ ^[0-9]+$ ]] || die "Invalid udp-port in ${config}: ${udp_port}"

  deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if service_active "${service}"; then
      pid="$(systemctl show --property MainPID --value "${service}" 2>/dev/null || true)"
      if [[ "${pid}" =~ ^[1-9][0-9]*$ && -e "/proc/${pid}/exe" ]]; then
        actual_binary="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
        if [[ "${actual_binary}" == "$(readlink -f "${expected_binary}")" ]]; then
          if [[ "${tcp_port}" == '0' ]] || listener_exists tcp "${tcp_port}"; then
            info "Health check passed: service active, executable matched, TCP port ${tcp_port} listening."
            if [[ "${udp_port}" != '0' ]] && ! listener_exists udp "${udp_port}"; then
              warn "UDP port ${udp_port} is not listening; DTLS may be disabled or still initializing."
            fi
            local release_root occtl
            release_root="$(dirname "$(dirname "${expected_binary}")")"
            if occtl="$(find_release_occtl "${release_root}" 2>/dev/null)"; then
              run_bounded "${occtl}" show status 2>/dev/null | sed -n '1,30p' || warn 'occtl status was unavailable; listener checks still passed.'
            fi
            return 0
          fi
        fi
      fi
    fi
    sleep 1
  done

  warn "Health check failed for ${service}."
  systemctl --no-pager --full status "${service}" 2>&1 | sed -n '1,80p' >&2 || true
  journalctl --no-pager -u "${service}" -n 60 2>&1 >&2 || true
  return 1
}

print_listener_summary() {
  local config="$1"
  local tcp_port udp_port
  tcp_port="$(configured_tcp_port "${config}" 2>/dev/null || true)"
  udp_port="$(configured_udp_port "${config}" 2>/dev/null || true)"
  printf 'Configured TCP port: %s; listening: ' "${tcp_port:-unknown}"
  if [[ "${tcp_port}" =~ ^[0-9]+$ ]] && listener_exists tcp "${tcp_port}"; then printf 'yes\n'; else printf 'no\n'; fi
  printf 'Configured UDP port: %s; listening: ' "${udp_port:-unknown}"
  if [[ "${udp_port}" =~ ^[0-9]+$ ]] && listener_exists udp "${udp_port}"; then printf 'yes\n'; else printf 'no\n'; fi
}
