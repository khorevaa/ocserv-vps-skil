#!/usr/bin/env bash

TO_VERSION=""
HEALTH_TIMEOUT="45"
APPROVE_RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to-version) TO_VERSION="${2:-}"; shift 2 ;;
    --health-timeout) HEALTH_TIMEOUT="${2:-}"; shift 2 ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) printf '%s\n' 'Usage: remote-rollback-release.sh --to-version <version|previous> --approve-restart'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
[[ -n "${TO_VERSION}" ]] || die '--to-version is required.'
[[ "${APPROVE_RESTART}" == "1" ]] || die '--approve-restart is required.'
[[ "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] && (( HEALTH_TIMEOUT >= 15 && HEALTH_TIMEOUT <= 300 )) || die 'Invalid health timeout.'
[[ -f "${OCSERV_STATE_FILE}" ]] || die 'Managed state is missing.'
for command in docker flock ss; do require_command "${command}"; done

install -d -m 0755 "$(dirname "${OCSERV_LOCK}")"
exec 9>"${OCSERV_LOCK}"
flock -n 9 || die 'Another ocserv VPS operation is running.'
ensure_openconnect_probe_tools

OLD_VERSION="$(state_get current_version)"
OLD_IMAGE="$(state_get current_image)"
DOMAIN="$(state_get domain)"
VPN_NETWORK="$(state_get vpn_network)"
VPN_PORT="$(state_get vpn_port)"

if [[ "${TO_VERSION}" == "previous" ]]; then
  TARGET_VERSION="$(state_get previous_version)"
  TARGET_IMAGE="$(state_get previous_image)"
  [[ -n "${TARGET_VERSION}" && -n "${TARGET_IMAGE}" ]] || die 'No previous image is recorded.'
else
  validate_version "${TO_VERSION}"
  TARGET_VERSION="${TO_VERSION}"
  mapfile -t metadata_files < <(grep -l -F "version=${TARGET_VERSION}" "${OCSERV_IMAGE_ROOT}"/*/metadata 2>/dev/null || true)
  (( ${#metadata_files[@]} == 1 )) || die "Expected exactly one retained image for version ${TARGET_VERSION}; found ${#metadata_files[@]}."
  TARGET_IMAGE="$(awk -F= '$1 == "image" {print substr($0, index($0, "=") + 1)}' "${metadata_files[0]}")"
fi

[[ "${TARGET_IMAGE}" != "${OLD_IMAGE}" ]] || die "${TARGET_IMAGE} is already active."
docker image inspect "${TARGET_IMAGE}" >/dev/null 2>&1 || die "Retained image is missing: ${TARGET_IMAGE}"
test_image_config "${TARGET_IMAGE}"
create_stack_backup "rollback-to-${TARGET_VERSION}"
BACKUP_DIR="${LAST_BACKUP}"

TARGET_SHA="$(docker image inspect --format '{{ index .Config.Labels "org.ocserv-vps.source-sha256" }}' "${TARGET_IMAGE}")"

ROLLBACK_COMMITTED="0"
PROBE_USER_CREATED="0"
PROBE_USERNAME=""
restore_original() {
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
  if [[ "${PROBE_USER_CREATED}" == "1" ]]; then
    delete_password_user "${TARGET_IMAGE}" "${PROBE_USERNAME}" >/dev/null 2>&1 || warn "Failed to remove temporary probe user ${PROBE_USERNAME}."
    docker kill --signal HUP "${OCSERV_CONTAINER}" >/dev/null 2>&1 || true
  fi
  if [[ "${status}" -ne 0 && "${ROLLBACK_COMMITTED}" != "1" ]]; then restore_original || true; fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' HUP INT TERM

info "Rolling back from ${OLD_VERSION} to ${TARGET_VERSION}; active VPN sessions will disconnect."
write_stack_env "${TARGET_IMAGE}"
compose up -d --remove-orphans
health_check_stack "${TARGET_IMAGE}" "${VPN_PORT}" "${HEALTH_TIMEOUT}" || die 'Rollback target failed health checks.'
PROBE_USERNAME="ocserv-check-$(openssl rand -hex 4)"
create_password_user "${TARGET_IMAGE}" "${PROBE_USERNAME}"
PROBE_PASSWORD="${GENERATED_VPN_PASSWORD}"
PROBE_USER_CREATED="1"
docker kill --signal HUP "${OCSERV_CONTAINER}" >/dev/null 2>&1 || true
verify_openconnect_data_path "${DOMAIN}" "${VPN_PORT}" "${PROBE_USERNAME}" "${PROBE_PASSWORD}"
delete_password_user "${TARGET_IMAGE}" "${PROBE_USERNAME}"
PROBE_USER_CREATED="0"
unset PROBE_PASSWORD GENERATED_VPN_PASSWORD
docker kill --signal HUP "${OCSERV_CONTAINER}" >/dev/null 2>&1 || true
write_state "${TARGET_VERSION}" "${TARGET_IMAGE}" "${OLD_VERSION}" "${OLD_IMAGE}" "${DOMAIN}" \
  "${VPN_NETWORK}" "${VPN_PORT}" "${TARGET_SHA}" "${BACKUP_DIR}"

ROLLBACK_COMMITTED="1"
info "Rollback succeeded: ${TARGET_VERSION} (${TARGET_IMAGE})."
info "Backup: ${BACKUP_DIR}"
