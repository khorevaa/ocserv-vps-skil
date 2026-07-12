#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

usage() {
  printf '%s\n' 'Usage: upgrade-ui.sh --host <ssh_target> --ui-version <version> --ui-image <image> --control-image <image> --approve-restart [--ssh-port <port>] [--identity-file <path>] [--accept-new-host-key] [--dry-run]'
}

HOST="" UI_VERSION="" UI_IMAGE="" CONTROL_IMAGE="" SSH_PORT="22" IDENTITY_FILE=""
ACCEPT_NEW_HOST_KEY="0" APPROVE_RESTART="0" DRY_RUN="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ocserv_require_value "$1" "${2:-}"; HOST="$2"; shift 2 ;;
    --ui-version) ocserv_require_value "$1" "${2:-}"; UI_VERSION="$2"; shift 2 ;;
    --ui-image) ocserv_require_value "$1" "${2:-}"; UI_IMAGE="$2"; shift 2 ;;
    --control-image) ocserv_require_value "$1" "${2:-}"; CONTROL_IMAGE="$2"; shift 2 ;;
    --ssh-port) ocserv_require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
    --identity-file) ocserv_require_value "$1" "${2:-}"; IDENTITY_FILE="$2"; shift 2 ;;
    --accept-new-host-key) ACCEPT_NEW_HOST_KEY="1"; shift ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
for value in HOST UI_VERSION UI_IMAGE CONTROL_IMAGE; do [[ -n "${!value}" ]] || { usage >&2; exit 2; }; done
ocserv_validate_version "${UI_VERSION}"
ocserv_validate_registry_image "${UI_IMAGE}"
ocserv_validate_registry_image "${CONTROL_IMAGE}"
[[ "${UI_IMAGE}" == "ghcr.io/khorevaa/ocserv-vps-ui:${UI_VERSION}" ]]
[[ "${CONTROL_IMAGE}" == "ghcr.io/khorevaa/ocserv-vps-control:${UI_VERSION}" ]]
ocserv_validate_port 'SSH port' "${SSH_PORT}"
[[ "${APPROVE_RESTART}" == 1 ]] || { printf '%s\n' '--approve-restart is required.' >&2; exit 2; }
if [[ "${DRY_RUN}" == 1 ]]; then
  printf 'UI upgrade plan:\n  host=%s\n  version=%s\n  preserve=access secret, browser hostname, port, sessions JSON\n  rollback=previous UI/control images and Compose/config\n' "${HOST}" "${UI_VERSION}"
  exit 0
fi
ocserv_run_remote "${SCRIPT_DIR}/remote/upgrade-ui.sh" "${HOST}" "" "${SSH_PORT}" "${IDENTITY_FILE}" "${ACCEPT_NEW_HOST_KEY}" \
  --ui-version "${UI_VERSION}" --ui-image "${UI_IMAGE}" --control-image "${CONTROL_IMAGE}" --approve-restart
