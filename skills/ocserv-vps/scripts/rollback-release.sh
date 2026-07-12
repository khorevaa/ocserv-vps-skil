#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

usage() {
  cat <<'EOF'
Usage:
  rollback-release.sh --host <ssh_target> --to-version <version|previous> \
    --approve-restart [options]

Options:
  --config <absolute_path>       Default: /etc/ocserv/ocserv.conf
  --health-timeout <seconds>     Default: 30
  --ssh-port <port>              Default: 22
  --identity-file <path>
  --ssh-password <pass>
  --accept-new-host-key
  --approve-restart              Required acknowledgment of disconnect.
  -h, --help
EOF
}

HOST=""
TO_VERSION=""
CONFIG="/etc/ocserv/ocserv.conf"
HEALTH_TIMEOUT="30"
SSH_PORT="22"
IDENTITY_FILE=""
SSH_PASSWORD=""
ACCEPT_NEW_HOST_KEY="0"
APPROVE_RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ocserv_require_value "$1" "${2:-}"; HOST="$2"; shift 2 ;;
    --to-version) ocserv_require_value "$1" "${2:-}"; TO_VERSION="$2"; shift 2 ;;
    --config) ocserv_require_value "$1" "${2:-}"; CONFIG="$2"; shift 2 ;;
    --health-timeout) ocserv_require_value "$1" "${2:-}"; HEALTH_TIMEOUT="$2"; shift 2 ;;
    --ssh-port) ocserv_require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
    --identity-file) ocserv_require_value "$1" "${2:-}"; IDENTITY_FILE="$2"; shift 2 ;;
    --ssh-password) ocserv_require_value "$1" "${2:-}"; SSH_PASSWORD="$2"; shift 2 ;;
    --accept-new-host-key) ACCEPT_NEW_HOST_KEY="1"; shift ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "${HOST}" || -z "${TO_VERSION}" ]]; then
  printf '%s\n' '--host and --to-version are required.' >&2
  usage >&2
  exit 2
fi
if [[ "${TO_VERSION}" != "previous" && ! "${TO_VERSION}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]]; then
  printf 'Unsafe target version: %s\n' "${TO_VERSION}" >&2
  exit 2
fi
if [[ "${APPROVE_RESTART}" != "1" ]]; then
  printf '%s\n' 'Refusing rollback: --approve-restart is required because active VPN sessions will disconnect.' >&2
  exit 2
fi
if [[ ! "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] || (( HEALTH_TIMEOUT < 5 || HEALTH_TIMEOUT > 300 )); then
  printf '%s\n' '--health-timeout must be an integer from 5 to 300.' >&2
  exit 2
fi
ocserv_validate_ssh_port "${SSH_PORT}"

ocserv_run_remote \
  "${SCRIPT_DIR}/remote/rollback-release.sh" \
  "${HOST}" "${SSH_PASSWORD}" "${SSH_PORT}" "${IDENTITY_FILE}" "${ACCEPT_NEW_HOST_KEY}" \
  --to-version "${TO_VERSION}" \
  --config "${CONFIG}" \
  --health-timeout "${HEALTH_TIMEOUT}" \
  --approve-restart
