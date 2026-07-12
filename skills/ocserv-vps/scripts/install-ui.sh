#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

usage() {
  cat <<'EOF'
Usage:
  install-ui.sh --host <ssh_target> --ui-version <version> \
    --ui-image <ghcr.io/owner/image:version> \
    --control-image <ghcr.io/owner/image:version> \
    --approve-restart [options]

Install the Dockerized ocserv management UI on a root-only Unix socket without
creating any VPS TCP listener. Use SSH local forwarding to reach it. Independent
One high-entropy UI access secret is generated on the VPS and handed off only
through a root-readable file. It directly creates the operator session.

Options:
  --ui-port <port>           Local tunnel/browser port. Default: 8765
  --ssh-port <port>          Default: 22
  --identity-file <path>
  --ssh-password <pass>
  --accept-new-host-key
  --approve-restart
  --dry-run
  -h, --help
EOF
}

HOST=""
UI_VERSION=""
UI_IMAGE=""
CONTROL_IMAGE=""
UI_PORT="8765"
SSH_PORT="22"
IDENTITY_FILE=""
SSH_PASSWORD=""
ACCEPT_NEW_HOST_KEY="0"
APPROVE_RESTART="0"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ocserv_require_value "$1" "${2:-}"; HOST="$2"; shift 2 ;;
    --ui-version) ocserv_require_value "$1" "${2:-}"; UI_VERSION="$2"; shift 2 ;;
    --ui-image) ocserv_require_value "$1" "${2:-}"; UI_IMAGE="$2"; shift 2 ;;
    --control-image) ocserv_require_value "$1" "${2:-}"; CONTROL_IMAGE="$2"; shift 2 ;;
    --ui-port) ocserv_require_value "$1" "${2:-}"; UI_PORT="$2"; shift 2 ;;
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

for value in HOST UI_VERSION UI_IMAGE CONTROL_IMAGE; do
  [[ -n "${!value}" ]] || { printf 'Required value is missing: %s\n' "${value}" >&2; exit 2; }
done
ocserv_validate_version "${UI_VERSION}"
ocserv_validate_registry_image "${UI_IMAGE}"
ocserv_validate_registry_image "${CONTROL_IMAGE}"
[[ "${UI_IMAGE}" == "ghcr.io/khorevaa/ocserv-vps-ui:${UI_VERSION}" ]] || {
  printf '%s\n' 'UI image must be ghcr.io/khorevaa/ocserv-vps-ui:<ui-version>.' >&2
  exit 2
}
[[ "${CONTROL_IMAGE}" == "ghcr.io/khorevaa/ocserv-vps-control:${UI_VERSION}" ]] || {
  printf '%s\n' 'Control image must be ghcr.io/khorevaa/ocserv-vps-control:<ui-version>.' >&2
  exit 2
}
ocserv_validate_port 'local tunnel port' "${UI_PORT}"
ocserv_validate_port 'SSH port' "${SSH_PORT}"
[[ "${APPROVE_RESTART}" == "1" ]] || { printf '%s\n' '--approve-restart is required.' >&2; exit 2; }

if [[ "${DRY_RUN}" == "1" ]]; then
  cat <<EOF
UI installation plan:
  host=${HOST}
  ui_version=${UI_VERSION}
  ui_image=${UI_IMAGE}
  control_image=${CONTROL_IMAGE}
  browser_url=http://ocserv-<random-128-bit>.localhost:${UI_PORT}
  transport=SSH local forward directly to /run/ocserv-ui-web/web.sock
  host_identity=reserve locked nologin ocserv-ui-host uid/gid 10001 after collision check
  access_gate=generate one 256-bit secret; exchange it directly for the operator session
  session_cookie=Secure/HttpOnly/SameSite=Strict; maximum 12 hours
  remote_ingress=none; do not change nginx, ACME, or firewall
  vpn=retain direct TCP/UDP ownership of its existing port
  docker_socket=never mounted into UI containers
  post_install_check=UI API add/rotate plus OpenConnect tunneled HTTPS for both generated passwords
No SSH connection was made.
EOF
  exit 0
fi

ocserv_run_remote \
  "${SCRIPT_DIR}/remote/install-ui.sh" \
  "${HOST}" "${SSH_PASSWORD}" "${SSH_PORT}" "${IDENTITY_FILE}" "${ACCEPT_NEW_HOST_KEY}" \
  --ui-version "${UI_VERSION}" \
  --ui-image "${UI_IMAGE}" \
  --control-image "${CONTROL_IMAGE}" \
  --ui-port "${UI_PORT}" \
  --ssh-port "${SSH_PORT}" \
  --approve-restart
