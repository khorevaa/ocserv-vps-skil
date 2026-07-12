#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

usage() {
  cat <<'EOF'
Usage:
  bootstrap-vps.sh --host <ssh_target> --domain <fqdn> --acme-email <email> \
    --vpn-username <name> --version <version> \
    --image <ghcr.io/owner/image:version> \
    --approve-firewall --approve-restart [options]

Options:
  --vpn-network <cidr>          Default: 10.66.0.0/24
  --vpn-port <port>            TCP and UDP port. Default: 443
  --dns-primary <address>      Default: 1.1.1.1
  --dns-secondary <address>    Default: 1.0.0.1
  --public-interface <name>    Auto-detected when omitted.
  --prepare-nginx              Install nginx and an ACME webroot site for a future UI.
  --ssh-port <port>            SSH connection and firewall port. Default: 22
  --identity-file <path>
  --ssh-password <pass>
  --accept-new-host-key
  --approve-firewall
  --approve-restart
  --dry-run
  -h, --help
EOF
}

HOST=""
DOMAIN=""
ACME_EMAIL=""
VPN_USERNAME=""
VERSION=""
IMAGE=""
VPN_NETWORK="10.66.0.0/24"
VPN_PORT="443"
DNS_PRIMARY="1.1.1.1"
DNS_SECONDARY="1.0.0.1"
PUBLIC_INTERFACE=""
PREPARE_NGINX="0"
SSH_PORT="22"
IDENTITY_FILE=""
SSH_PASSWORD=""
ACCEPT_NEW_HOST_KEY="0"
APPROVE_FIREWALL="0"
APPROVE_RESTART="0"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ocserv_require_value "$1" "${2:-}"; HOST="$2"; shift 2 ;;
    --domain) ocserv_require_value "$1" "${2:-}"; DOMAIN="$2"; shift 2 ;;
    --acme-email) ocserv_require_value "$1" "${2:-}"; ACME_EMAIL="$2"; shift 2 ;;
    --vpn-username) ocserv_require_value "$1" "${2:-}"; VPN_USERNAME="$2"; shift 2 ;;
    --version) ocserv_require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --image) ocserv_require_value "$1" "${2:-}"; IMAGE="$2"; shift 2 ;;
    --vpn-network) ocserv_require_value "$1" "${2:-}"; VPN_NETWORK="$2"; shift 2 ;;
    --vpn-port) ocserv_require_value "$1" "${2:-}"; VPN_PORT="$2"; shift 2 ;;
    --dns-primary) ocserv_require_value "$1" "${2:-}"; DNS_PRIMARY="$2"; shift 2 ;;
    --dns-secondary) ocserv_require_value "$1" "${2:-}"; DNS_SECONDARY="$2"; shift 2 ;;
    --public-interface) ocserv_require_value "$1" "${2:-}"; PUBLIC_INTERFACE="$2"; shift 2 ;;
    --prepare-nginx) PREPARE_NGINX="1"; shift ;;
    --ssh-port) ocserv_require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
    --identity-file) ocserv_require_value "$1" "${2:-}"; IDENTITY_FILE="$2"; shift 2 ;;
    --ssh-password) ocserv_require_value "$1" "${2:-}"; SSH_PASSWORD="$2"; shift 2 ;;
    --accept-new-host-key) ACCEPT_NEW_HOST_KEY="1"; shift ;;
    --approve-firewall) APPROVE_FIREWALL="1"; shift ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for value in HOST DOMAIN ACME_EMAIL VPN_USERNAME VERSION IMAGE; do
  [[ -n "${!value}" ]] || { printf 'Required value is missing: %s\n' "${value}" >&2; exit 2; }
done
ocserv_validate_domain "${DOMAIN}"
ocserv_validate_version "${VERSION}"
ocserv_validate_registry_image "${IMAGE}"
ocserv_validate_cidr "${VPN_NETWORK}"
ocserv_validate_port 'VPN port' "${VPN_PORT}"
ocserv_validate_port 'SSH port' "${SSH_PORT}"
[[ "${ACME_EMAIL}" == *@*.* ]] || { printf '%s\n' 'Invalid ACME email.' >&2; exit 2; }
[[ "${VPN_USERNAME}" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || { printf '%s\n' 'Unsafe VPN username.' >&2; exit 2; }
[[ "${APPROVE_FIREWALL}" == "1" ]] || { printf '%s\n' '--approve-firewall is required.' >&2; exit 2; }
[[ "${APPROVE_RESTART}" == "1" ]] || { printf '%s\n' '--approve-restart is required.' >&2; exit 2; }

if [[ "${DRY_RUN}" == "1" ]]; then
  cat <<EOF
Bootstrap plan:
  host=${HOST}
  domain=${DOMAIN}
  version=${VERSION}
  image=${IMAGE}
  vpn_network=${VPN_NETWORK}
  vpn_port=${VPN_PORT}/tcp+udp
  ssh_port=${SSH_PORT}/tcp
  prepare_nginx=${PREPARE_NGINX}
  initial_user=${VPN_USERNAME}
  docker=preserve when present; install only when absent
  post_deploy_check=mandatory OpenConnect login plus tunneled HTTPS
No SSH connection was made.
EOF
  exit 0
fi

remote_args=(
  --domain "${DOMAIN}" --acme-email "${ACME_EMAIL}" --vpn-username "${VPN_USERNAME}"
  --version "${VERSION}" --image "${IMAGE}" --vpn-network "${VPN_NETWORK}" --vpn-port "${VPN_PORT}"
  --dns-primary "${DNS_PRIMARY}" --dns-secondary "${DNS_SECONDARY}"
  --ssh-port "${SSH_PORT}" --approve-firewall --approve-restart
)
[[ -z "${PUBLIC_INTERFACE}" ]] || remote_args+=(--public-interface "${PUBLIC_INTERFACE}")
[[ "${PREPARE_NGINX}" == "0" ]] || remote_args+=(--prepare-nginx)

ocserv_run_remote "${SCRIPT_DIR}/remote/bootstrap-vps.sh" \
  "${HOST}" "${SSH_PASSWORD}" "${SSH_PORT}" "${IDENTITY_FILE}" "${ACCEPT_NEW_HOST_KEY}" "${remote_args[@]}"
