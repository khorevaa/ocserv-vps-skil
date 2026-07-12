#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

usage() {
  cat <<'EOF'
Usage:
  rotate-ui-access.sh --host <ssh_target> --approve-restart [options]

Generate a new UI access secret on the VPS, revoke existing operator sessions,
and recreate only the unprivileged UI web container. The secret is never
printed; retrieve it from the root-only handoff file reported by the script.

Options:
  --ssh-port <port>          Default: 22
  --identity-file <path>
  --ssh-password <pass>
  --accept-new-host-key
  --approve-restart
  -h, --help
EOF
}

HOST=""
SSH_PORT="22"
IDENTITY_FILE=""
SSH_PASSWORD=""
ACCEPT_NEW_HOST_KEY="0"
APPROVE_RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ocserv_require_value "$1" "${2:-}"; HOST="$2"; shift 2 ;;
    --ssh-port) ocserv_require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
    --identity-file) ocserv_require_value "$1" "${2:-}"; IDENTITY_FILE="$2"; shift 2 ;;
    --ssh-password) ocserv_require_value "$1" "${2:-}"; SSH_PASSWORD="$2"; shift 2 ;;
    --accept-new-host-key) ACCEPT_NEW_HOST_KEY="1"; shift ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${HOST}" ]] || { printf '%s\n' '--host is required.' >&2; exit 2; }
[[ "${APPROVE_RESTART}" == "1" ]] || { printf '%s\n' '--approve-restart is required.' >&2; exit 2; }
ocserv_validate_port 'SSH port' "${SSH_PORT}"

ocserv_run_remote \
  "${SCRIPT_DIR}/remote/rotate-ui-access.sh" \
  "${HOST}" "${SSH_PASSWORD}" "${SSH_PORT}" "${IDENTITY_FILE}" "${ACCEPT_NEW_HOST_KEY}" \
  --approve-restart
