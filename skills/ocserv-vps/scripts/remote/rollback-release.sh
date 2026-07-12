#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage: remote-rollback-release.sh --to-version <version|previous>
  [--config <path>] [--health-timeout <seconds>] --approve-restart
EOF
}

TO_VERSION=""
CONFIG="/etc/ocserv/ocserv.conf"
HEALTH_TIMEOUT="30"
APPROVE_RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to-version) TO_VERSION="${2:-}"; shift 2 ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --health-timeout) HEALTH_TIMEOUT="${2:-}"; shift 2 ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
[[ -n "${TO_VERSION}" ]] || die '--to-version is required.'
[[ "${APPROVE_RESTART}" == '1' ]] || die '--approve-restart is required.'
validate_config_path "${CONFIG}"
[[ "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] && (( HEALTH_TIMEOUT >= 5 && HEALTH_TIMEOUT <= 300 )) || die 'Invalid health timeout.'
require_command systemctl
require_command flock
require_command ss
[[ -r "${CONFIG}" ]] || die "Config is not readable: ${CONFIG}"
service_exists "${OCSERV_SERVICE}" || die "Managed service is not installed: ${OCSERV_SERVICE}"

install -d -m 0755 "$(dirname "${OCSERV_LOCK}")"
exec 9>"${OCSERV_LOCK}"
flock -n 9 || die 'Another ocserv release operation is running.'

if [[ "${TO_VERSION}" == 'previous' ]]; then
  TO_VERSION="$(state_get previous_version || true)"
  [[ -n "${TO_VERSION}" ]] || die 'State file does not contain a previous version.'
fi
validate_version "${TO_VERSION}"
TARGET_RELEASE="${OCSERV_RELEASES_DIR}/${TO_VERSION}"
[[ -d "${TARGET_RELEASE}" ]] || die "Retained release does not exist: ${TARGET_RELEASE}"
TARGET_BINARY="$(find_release_ocserv "${TARGET_RELEASE}" 2>/dev/null || true)"
[[ -n "${TARGET_BINARY}" ]] || die "Retained release has no ocserv binary: ${TARGET_RELEASE}"
[[ -x "${TARGET_RELEASE}/ocserv" ]] || die "Retained release lacks the managed entrypoint: ${TARGET_RELEASE}/ocserv"

OLD_TARGET="$(readlink -f "${OCSERV_CURRENT_LINK}" 2>/dev/null || true)"
[[ -n "${OLD_TARGET}" ]] || die 'Current release symlink is missing.'
OLD_VERSION="$(version_from_release_path "${OLD_TARGET}" || true)"
[[ "${OLD_TARGET}" != "${TARGET_RELEASE}" ]] || die "Release ${TO_VERSION} is already active."
OLD_BINARY="$(find_release_ocserv "${OLD_TARGET}" 2>/dev/null || true)"
[[ -n "${OLD_BINARY}" ]] || die 'Current release has no ocserv binary; refusing rollback transaction.'

TEST_LOG="$(mktemp /var/tmp/ocserv-rollback-config.XXXXXX)"
trap 'rm -f "${TEST_LOG}"' EXIT
if ! test_ocserv_config "${TARGET_BINARY}" "${CONFIG}" >"${TEST_LOG}" 2>&1; then
  sed -n '1,120p' "${TEST_LOG}" >&2
  die "Target release ${TO_VERSION} rejects the current configuration; live service was not changed."
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${OCSERV_BACKUP_ROOT}/${TIMESTAMP}-rollback-to-${TO_VERSION}"
install -d -m 0700 "${BACKUP_DIR}"
CONFIG_BACKUP_SCOPE="$(config_backup_scope "${CONFIG}")"
tar -C / -cpf "${BACKUP_DIR}/etc-ocserv.tar" "${CONFIG_BACKUP_SCOPE#/}" 2>/dev/null || die 'Could not snapshot the configuration.'
printf '%s\n' "${OLD_TARGET}" > "${BACKUP_DIR}/previous-current-target"
cp -a "${OCSERV_UNIT}" "${BACKUP_DIR}/ocserv-release.service"
[[ ! -f "${OCSERV_STATE_FILE}" ]] || cp -a "${OCSERV_STATE_FILE}" "${BACKUP_DIR}/previous-state"

CUTOVER_STARTED='0'
ROLLBACK_COMMITTED='0'

restore_original_release() {
  warn "Restoring ${OLD_VERSION:-the original release}."
  set +e
  systemctl stop "${OCSERV_SERVICE}" >/dev/null 2>&1
  atomic_current_link "${OLD_TARGET}"
  systemctl start "${OCSERV_SERVICE}" >/dev/null 2>&1
  health_check_release "${OCSERV_SERVICE}" "${OLD_BINARY}" "${CONFIG}" "${HEALTH_TIMEOUT}" >/dev/null 2>&1
  CUTOVER_STARTED='0'
  set -e
}

rollback_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${status}" -ne 0 && "${CUTOVER_STARTED}" == '1' && "${ROLLBACK_COMMITTED}" != '1' ]]; then
    restore_original_release || true
  fi
  rm -f "${TEST_LOG}"
  exit "${status}"
}

rollback_signal() {
  exit 130
}

trap rollback_exit EXIT
trap rollback_signal HUP INT TERM

info "Rolling back from ${OLD_VERSION:-unknown} to ${TO_VERSION}; active VPN sessions will disconnect."
CUTOVER_STARTED='1'
systemctl stop "${OCSERV_SERVICE}"
atomic_current_link "${TARGET_RELEASE}"

if ! systemctl start "${OCSERV_SERVICE}" || ! health_check_release "${OCSERV_SERVICE}" "${TARGET_BINARY}" "${CONFIG}" "${HEALTH_TIMEOUT}"; then
  restore_original_release
  die "Rollback failed and the original release was restored. Backup: ${BACKUP_DIR}"
fi

legacy_service="$(state_get legacy_service || true)"
legacy_was_active="$(state_get legacy_was_active || true)"
legacy_was_enabled="$(state_get legacy_was_enabled || true)"
[[ -n "${legacy_was_active}" ]] || legacy_was_active='0'
[[ -n "${legacy_was_enabled}" ]] || legacy_was_enabled='0'
write_state "${TO_VERSION}" "${OLD_VERSION}" "${legacy_service}" "${legacy_was_active}" "${legacy_was_enabled}" "${BACKUP_DIR}"
ROLLBACK_COMMITTED='1'
CUTOVER_STARTED='0'
info "Rollback succeeded: ${TO_VERSION} is active."
info "Backup: ${BACKUP_DIR}"
