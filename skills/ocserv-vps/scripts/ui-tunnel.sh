#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

usage() {
  cat <<'EOF'
Usage:
  ui-tunnel.sh --host <ssh_target> [options]

Open a local-only browser endpoint and forward it through SSH directly to the
remote ocserv UI Unix socket. The VPS does not expose a UI TCP listener.

Options:
  --local-port <port>        Optional expected port; normally read from the VPS
  --ssh-port <port>          Default: 22
  --identity-file <path>
  --ssh-password <pass>
  --accept-new-host-key
  -h, --help
EOF
}

HOST=""
LOCAL_PORT=""
SSH_PORT="22"
IDENTITY_FILE=""
SSH_PASSWORD=""
ACCEPT_NEW_HOST_KEY="0"
REMOTE_SOCKET="/run/ocserv-ui-web/web.sock"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ocserv_require_value "$1" "${2:-}"; HOST="$2"; shift 2 ;;
    --local-port) ocserv_require_value "$1" "${2:-}"; LOCAL_PORT="$2"; shift 2 ;;
    --ssh-port) ocserv_require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
    --identity-file) ocserv_require_value "$1" "${2:-}"; IDENTITY_FILE="$2"; shift 2 ;;
    --ssh-password) ocserv_require_value "$1" "${2:-}"; SSH_PASSWORD="$2"; shift 2 ;;
    --accept-new-host-key) ACCEPT_NEW_HOST_KEY="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${HOST}" ]] || { printf '%s\n' '--host is required.' >&2; exit 2; }
ocserv_validate_ssh_target "${HOST}"
[[ -z "${LOCAL_PORT}" ]] || ocserv_validate_port 'local UI port' "${LOCAL_PORT}"
ocserv_validate_port 'SSH port' "${SSH_PORT}"

ssh_common_args=(
  -T
  -p "${SSH_PORT}"
  -o ExitOnForwardFailure=yes
  -o ConnectTimeout=15
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
)
if [[ -n "${IDENTITY_FILE}" ]]; then
  ssh_common_args+=( -i "${IDENTITY_FILE}" -o IdentitiesOnly=yes )
fi
if [[ "${ACCEPT_NEW_HOST_KEY}" == "1" ]]; then
  ssh_common_args+=( -o StrictHostKeyChecking=accept-new )
fi
if [[ -z "${SSH_PASSWORD}" ]]; then
  ssh_common_args+=( -o BatchMode=yes )
fi

runner=(bash "${SCRIPT_DIR}/ssh-with-password.sh")
if [[ -n "${SSH_PASSWORD}" ]]; then
  runner+=(--ssh-password "${SSH_PASSWORD}")
fi

metadata="$("${runner[@]}" "${ssh_common_args[@]}" -- "${HOST}" \
  "grep -E '^OCSERV_UI_LOCAL_(HOST|PORT)=' /opt/ocserv-vps/ui.env")" || {
  printf '%s\n' 'Cannot read the installed UI tunnel metadata from the VPS.' >&2
  exit 1
}
BROWSER_HOST="$(awk -F= '$1 == "OCSERV_UI_LOCAL_HOST" {print substr($0, index($0, "=") + 1)}' <<<"${metadata}")"
CONFIGURED_PORT="$(awk -F= '$1 == "OCSERV_UI_LOCAL_PORT" {print substr($0, index($0, "=") + 1)}' <<<"${metadata}")"
[[ "${BROWSER_HOST}" =~ ^ocserv-[0-9a-f]{32}\.localhost$ ]] || {
  printf '%s\n' 'The VPS returned an unsafe UI browser hostname.' >&2
  exit 1
}
ocserv_validate_port 'installed local UI port' "${CONFIGURED_PORT}"
if [[ -n "${LOCAL_PORT}" && "${LOCAL_PORT}" != "${CONFIGURED_PORT}" ]]; then
  printf 'Requested local port %s does not match the installed UI origin port %s.\n' \
    "${LOCAL_PORT}" "${CONFIGURED_PORT}" >&2
  exit 2
fi
LOCAL_PORT="${CONFIGURED_PORT}"

printf 'SSH-only UI tunnel: http://%s:%s/\n' "${BROWSER_HOST}" "${LOCAL_PORT}"
printf '%s\n' 'Keep this process running while the UI is in use; press Ctrl+C to close it.'

exec "${runner[@]}" "${ssh_common_args[@]}" -N \
  -L "localhost:${LOCAL_PORT}:${REMOTE_SOCKET}" -- "${HOST}"
