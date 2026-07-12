#!/usr/bin/env bash

VERSION=""
IMAGE=""
HEALTH_TIMEOUT="45"
APPROVE_RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --health-timeout) HEALTH_TIMEOUT="${2:-}"; shift 2 ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) printf '%s\n' 'Usage: remote-deploy-release.sh --version <version> --image <ghcr-ref@sha256:digest> --approve-restart'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
[[ -n "${VERSION}" && -n "${IMAGE}" ]] || die '--version and --image are required.'
[[ "${APPROVE_RESTART}" == "1" ]] || die '--approve-restart is required.'
validate_version "${VERSION}"
validate_registry_image "${IMAGE}"
[[ "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] && (( HEALTH_TIMEOUT >= 15 && HEALTH_TIMEOUT <= 300 )) || die 'Invalid health timeout.'
[[ -f "${OCSERV_STATE_FILE}" && -f "${OCSERV_COMPOSE_FILE}" && -f "${OCSERV_ENV_FILE}" ]] || die 'Managed stack is missing. Run bootstrap-vps.sh first.'
for command in docker flock ss; do require_command "${command}"; done
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is unavailable.'

install -d -m 0755 "$(dirname "${OCSERV_LOCK}")"
exec 9>"${OCSERV_LOCK}"
flock -n 9 || die 'Another ocserv VPS operation is running.'

OLD_VERSION="$(state_get current_version)"
OLD_IMAGE="$(state_get current_image)"
DOMAIN="$(state_get domain)"
VPN_NETWORK="$(state_get vpn_network)"
VPN_PORT="$(state_get vpn_port)"
[[ -n "${OLD_VERSION}" && -n "${OLD_IMAGE}" && -n "${DOMAIN}" && -n "${VPN_PORT}" ]] || die 'Managed state is incomplete.'
[[ "${VERSION}" != "${OLD_VERSION}" || "${IMAGE}" != "${OLD_IMAGE}" ]] || die 'Requested version and image are already active.'

pull_verified_image "${IMAGE}" "${VERSION}"
NEW_IMAGE="${RESOLVED_IMAGE}"
test_image_config "${NEW_IMAGE}"
create_stack_backup "deploy-${VERSION}"
BACKUP_DIR="${LAST_BACKUP}"

ACTIVATION_COMMITTED="0"
restore_previous_image() {
  warn "Restoring ${OLD_IMAGE}."
  set +e
  write_stack_env "${OLD_IMAGE}"
  compose up -d --remove-orphans >/dev/null 2>&1
  health_check_stack "${OLD_IMAGE}" "${VPN_PORT}" "${HEALTH_TIMEOUT}" >/dev/null 2>&1
  set -e
}
on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${status}" -ne 0 && "${ACTIVATION_COMMITTED}" != "1" ]]; then restore_previous_image || true; fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' HUP INT TERM

info "Activating ${NEW_IMAGE}; active VPN sessions will disconnect."
write_stack_env "${NEW_IMAGE}"
compose up -d --remove-orphans
health_check_stack "${NEW_IMAGE}" "${VPN_PORT}" "${HEALTH_TIMEOUT}" || die 'New image failed health checks.'
write_state "${VERSION}" "${NEW_IMAGE}" "${OLD_VERSION}" "${OLD_IMAGE}" "${DOMAIN}" \
  "${VPN_NETWORK}" "${VPN_PORT}" "${RESOLVED_SOURCE_SHA}" "${BACKUP_DIR}"

ACTIVATION_COMMITTED="1"
info "Release ${VERSION} is active as ${NEW_IMAGE}."
info "Rollback target: ${OLD_VERSION} (${OLD_IMAGE})."
info "Backup: ${BACKUP_DIR}"
