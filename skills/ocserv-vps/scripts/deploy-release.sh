#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

usage() {
  cat <<'EOF'
Usage:
  deploy-release.sh --host <ssh_target> --version <version> \
    --image <ghcr.io/owner/image@sha256:digest> --approve-restart [options]

Pull, validate, and activate a new immutable GHCR image.

Options:
  --health-timeout <seconds>   Default: 45
  --ssh-port <port>           Default: 22
  --identity-file <path>
  --ssh-password <pass>
  --accept-new-host-key
  --approve-restart
  --dry-run
  -h, --help
EOF
}

HOST=""
VERSION=""
IMAGE=""
HEALTH_TIMEOUT="45"
SSH_PORT="22"
IDENTITY_FILE=""
SSH_PASSWORD=""
ACCEPT_NEW_HOST_KEY="0"
APPROVE_RESTART="0"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ocserv_require_value "$1" "${2:-}"; HOST="$2"; shift 2 ;;
    --version) ocserv_require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --image) ocserv_require_value "$1" "${2:-}"; IMAGE="$2"; shift 2 ;;
    --health-timeout) ocserv_require_value "$1" "${2:-}"; HEALTH_TIMEOUT="$2"; shift 2 ;;
    --ssh-port) ocserv_require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
    --identity-file) ocserv_require_value "$1" "${2:-}"; IDENTITY_FILE="$2"; shift 2 ;;
    --ssh-password) ocserv_require_value "$1" "${2:-}"; SSH_PASSWORD="$2"; shift 2 ;;
    --accept-new-host-key) ACCEPT_NEW_HOST_KEY="1"; shift ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${HOST}" && -n "${VERSION}" && -n "${IMAGE}" ]] || { printf '%s\n' '--host, --version, and --image are required.' >&2; exit 2; }
ocserv_validate_version "${VERSION}"
ocserv_validate_registry_image "${IMAGE}"
ocserv_validate_port 'SSH port' "${SSH_PORT}"
[[ "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] && (( HEALTH_TIMEOUT >= 15 && HEALTH_TIMEOUT <= 300 )) || { printf '%s\n' 'Invalid health timeout.' >&2; exit 2; }
[[ "${APPROVE_RESTART}" == "1" ]] || { printf '%s\n' '--approve-restart is required.' >&2; exit 2; }

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'GHCR release plan: host=%s version=%s image=%s health_timeout=%ss\n' "${HOST}" "${VERSION}" "${IMAGE}" "${HEALTH_TIMEOUT}"
  printf '%s\n' 'No SSH connection was made.'
  exit 0
fi

ocserv_run_remote "${SCRIPT_DIR}/remote/deploy-release.sh" \
  "${HOST}" "${SSH_PASSWORD}" "${SSH_PORT}" "${IDENTITY_FILE}" "${ACCEPT_NEW_HOST_KEY}" \
  --version "${VERSION}" --image "${IMAGE}" --health-timeout "${HEALTH_TIMEOUT}" --approve-restart
