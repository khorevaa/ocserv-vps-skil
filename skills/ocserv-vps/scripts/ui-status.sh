#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

usage() {
  cat <<'EOF'
Usage:
  ui-status.sh --host <ssh_target> [options]

Options:
  --ssh-port <port>          Default: 22
  --identity-file <path>
  --ssh-password <pass>
  --accept-new-host-key
  -h, --help
EOF
}

HOST=""
SSH_PORT="22"
IDENTITY_FILE=""
SSH_PASSWORD=""
ACCEPT_NEW_HOST_KEY="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ocserv_require_value "$1" "${2:-}"; HOST="$2"; shift 2 ;;
    --ssh-port) ocserv_require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
    --identity-file) ocserv_require_value "$1" "${2:-}"; IDENTITY_FILE="$2"; shift 2 ;;
    --ssh-password) ocserv_require_value "$1" "${2:-}"; SSH_PASSWORD="$2"; shift 2 ;;
    --accept-new-host-key) ACCEPT_NEW_HOST_KEY="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${HOST}" ]] || { printf '%s\n' '--host is required.' >&2; exit 2; }
ocserv_validate_port 'SSH port' "${SSH_PORT}"

ocserv_run_remote \
  "${SCRIPT_DIR}/remote/ui-status.sh" \
  "${HOST}" "${SSH_PASSWORD}" "${SSH_PORT}" "${IDENTITY_FILE}" "${ACCEPT_NEW_HOST_KEY}"
