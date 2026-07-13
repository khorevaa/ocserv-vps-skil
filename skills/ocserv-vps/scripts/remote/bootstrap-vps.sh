#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage: remote-bootstrap-vps.sh --domain <fqdn> --acme-email <email>
  --vpn-username <name> --version <version>
  --image <ghcr.io/owner/image:version>
  --vpn-network <cidr> --vpn-port <port> --ssh-port <port>
  --approve-firewall --approve-restart [--prepare-nginx]
EOF
}

DOMAIN=""
ACME_EMAIL=""
VPN_USERNAME=""
VERSION=""
IMAGE=""
VPN_NETWORK="10.66.0.0/24"
VPN_PORT="443"
DNS_PRIMARY="1.1.1.1"
DNS_SECONDARY="1.0.0.1"
SSH_PORT="22"
PUBLIC_INTERFACE=""
PREPARE_NGINX="0"
APPROVE_FIREWALL="0"
APPROVE_RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --acme-email) ACME_EMAIL="${2:-}"; shift 2 ;;
    --vpn-username) VPN_USERNAME="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --vpn-network) VPN_NETWORK="${2:-}"; shift 2 ;;
    --vpn-port) VPN_PORT="${2:-}"; shift 2 ;;
    --dns-primary) DNS_PRIMARY="${2:-}"; shift 2 ;;
    --dns-secondary) DNS_SECONDARY="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --public-interface) PUBLIC_INTERFACE="${2:-}"; shift 2 ;;
    --prepare-nginx) PREPARE_NGINX="1"; shift ;;
    --approve-firewall) APPROVE_FIREWALL="1"; shift ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
for value in DOMAIN ACME_EMAIL VPN_USERNAME VERSION IMAGE; do
  [[ -n "${!value}" ]] || die "Required value is missing: ${value}"
done
[[ "${APPROVE_FIREWALL}" == "1" ]] || die '--approve-firewall is required.'
[[ "${APPROVE_RESTART}" == "1" ]] || die '--approve-restart is required.'
validate_domain "${DOMAIN}"
validate_username "${VPN_USERNAME}"
validate_version "${VERSION}"
validate_registry_image "${IMAGE}"
validate_port 'VPN port' "${VPN_PORT}"
validate_port 'SSH port' "${SSH_PORT}"

[[ -r /etc/os-release ]] || die '/etc/os-release is unavailable.'
OS_ID="$(. /etc/os-release; printf '%s' "${ID:-}")"
case "${OS_ID}" in debian|ubuntu) ;; *) die "Unsupported OS: ${OS_ID:-unknown}" ;; esac
[[ -e /dev/net/tun ]] || die '/dev/net/tun is unavailable.'
[[ ! -e "${OCSERV_STATE_FILE}" ]] || die 'Managed ocserv stack already exists. Use deploy-release.sh for upgrades.'
[[ "$(docker inspect --format '{{.State.Running}}' "${OCSERV_CONTAINER}" 2>/dev/null || true)" != "true" ]] || die 'Container ocserv-vps is already running.'

acquire_stack_locks

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl python3 openssl certbot iproute2 iptables \
  openconnect vpnc-scripts
install_docker_engine

validate_ipv4_cidr "${VPN_NETWORK}" || die "Invalid VPN network: ${VPN_NETWORK}"
if [[ -z "${PUBLIC_INTERFACE}" ]]; then
  PUBLIC_INTERFACE="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
fi
validate_interface "${PUBLIC_INTERFACE}"
ip link show "${PUBLIC_INTERFACE}" >/dev/null 2>&1 || die "Public interface not found: ${PUBLIC_INTERFACE}"
getent ahostsv4 "${DOMAIN}" >/dev/null 2>&1 || die "Domain does not resolve to IPv4: ${DOMAIN}"

if ss -H -ltn | awk '$4 ~ /:80$/ {found=1} END {exit(found ? 0 : 1)}'; then
  if [[ "${PREPARE_NGINX}" != "1" ]]; then
    die 'TCP port 80 is occupied. Rerun with --prepare-nginx only when nginx owns it, or free the port for standalone ACME.'
  fi
  systemctl is-active --quiet nginx || die 'TCP port 80 is occupied by a service other than active nginx.'
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BOOTSTRAP_BACKUP="${OCSERV_BACKUP_ROOT}/${TIMESTAMP}-before-bootstrap"
install -d -m 0700 "${BOOTSTRAP_BACKUP}"
iptables-save > "${BOOTSTRAP_BACKUP}/iptables.rules"
ip6tables-save > "${BOOTSTRAP_BACKUP}/ip6tables.rules" 2>/dev/null || true
sysctl -n net.ipv4.ip_forward > "${BOOTSTRAP_BACKUP}/ipv4-forwarding" 2>/dev/null || printf '0\n' > "${BOOTSTRAP_BACKUP}/ipv4-forwarding"
for path in /etc/sysctl.d/99-ocserv-vps.conf "${OCSERV_NETWORK_SCRIPT}" "${OCSERV_NETWORK_SERVICE}"; do
  [[ ! -e "${path}" ]] || cp -a "${path}" "${BOOTSTRAP_BACKUP}/"
done

BOOTSTRAP_COMMITTED="0"
rollback_bootstrap() {
  warn 'Bootstrap failed; stopping the new stack and restoring the previous firewall rules.'
  set +e
  if docker inspect "${OCSERV_CONTAINER}" >/dev/null 2>&1; then
    docker logs --tail 200 "${OCSERV_CONTAINER}" > "${BOOTSTRAP_BACKUP}/ocserv-container.log" 2>&1
    warn "Container logs saved to ${BOOTSTRAP_BACKUP}/ocserv-container.log."
    sed -n '1,200p' "${BOOTSTRAP_BACKUP}/ocserv-container.log" >&2
  fi
  if [[ -f "${OCSERV_COMPOSE_FILE}" && -f "${OCSERV_ENV_FILE}" ]]; then compose down >/dev/null 2>&1; fi
  iptables-restore < "${BOOTSTRAP_BACKUP}/iptables.rules"
  [[ ! -s "${BOOTSTRAP_BACKUP}/ip6tables.rules" ]] || ip6tables-restore < "${BOOTSTRAP_BACKUP}/ip6tables.rules"
  systemctl disable --now ocserv-vps-network.service >/dev/null 2>&1
  for pair in \
    "${OCSERV_NETWORK_SERVICE}:ocserv-vps-network.service" \
    "${OCSERV_NETWORK_SCRIPT}:apply-network.sh" \
    "/etc/sysctl.d/99-ocserv-vps.conf:99-ocserv-vps.conf"; do
    original="${pair%%:*}"
    saved="${BOOTSTRAP_BACKUP}/${pair#*:}"
    if [[ -f "${saved}" ]]; then cp -a "${saved}" "${original}"; else rm -f "${original}"; fi
  done
  sysctl -w "net.ipv4.ip_forward=$(cat "${BOOTSTRAP_BACKUP}/ipv4-forwarding")" >/dev/null 2>&1
  rm -f /root/ocserv-vps-initial-credentials
  systemctl daemon-reload >/dev/null 2>&1
  set -e
}
on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${status}" -ne 0 && "${BOOTSTRAP_COMMITTED}" != "1" ]]; then rollback_bootstrap || true; fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' HUP INT TERM

install -d -m 0750 "${OCSERV_STACK_ROOT}" "${OCSERV_CONFIG_DIR}" "${OCSERV_IMAGE_ROOT}" "${OCSERV_BIN_DIR}"
pull_verified_image "${IMAGE}" "${VERSION}"
IMAGE="${RESOLVED_IMAGE}"

render_ocserv_config "${DOMAIN}" "${VPN_NETWORK}" "${VPN_PORT}" "${DNS_PRIMARY}" "${DNS_SECONDARY}"
render_compose_file
write_stack_env "${IMAGE}"
create_password_user "${IMAGE}" "${VPN_USERNAME}"
cat > /root/ocserv-vps-initial-credentials <<EOF
username=${VPN_USERNAME}
password=${GENERATED_VPN_PASSWORD}
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 /root/ocserv-vps-initial-credentials

render_network_assets "${VPN_NETWORK}" "${VPN_PORT}" "${SSH_PORT}" "${PUBLIC_INTERFACE}"

if [[ "${PREPARE_NGINX}" == "1" ]]; then
  apt-get install -y --no-install-recommends nginx
  install -d -m 0755 /var/www/ocserv-acme/.well-known/acme-challenge
  cat > /etc/nginx/sites-available/ocserv-ui-bootstrap.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/ocserv-acme;
        default_type text/plain;
    }

    location / {
        return 404;
    }
}
EOF
  ln -sfn /etc/nginx/sites-available/ocserv-ui-bootstrap.conf /etc/nginx/sites-enabled/ocserv-ui-bootstrap.conf
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  certbot certonly --webroot -w /var/www/ocserv-acme \
    --non-interactive --agree-tos --keep-until-expiring \
    --email "${ACME_EMAIL}" -d "${DOMAIN}"
else
  certbot certonly --standalone \
    --non-interactive --agree-tos --keep-until-expiring \
    --email "${ACME_EMAIL}" -d "${DOMAIN}"
fi

install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/ocserv-vps-reload.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if docker inspect ocserv-vps >/dev/null 2>&1; then
  docker kill --signal HUP ocserv-vps >/dev/null || docker restart ocserv-vps >/dev/null
fi
EOF
chmod 0750 /etc/letsencrypt/renewal-hooks/deploy/ocserv-vps-reload.sh

test_image_config "${IMAGE}"
compose up -d --remove-orphans
health_check_stack "${IMAGE}" "${VPN_PORT}" 60 || die 'Initial container health check failed.'
verify_openconnect_data_path "${DOMAIN}" "${VPN_PORT}" "${VPN_USERNAME}" "${GENERATED_VPN_PASSWORD}"
write_state "${VERSION}" "${IMAGE}" "" "" "${DOMAIN}" "${VPN_NETWORK}" "${VPN_PORT}" \
  "${RESOLVED_SOURCE_SHA}" "${BOOTSTRAP_BACKUP}"

BOOTSTRAP_COMMITTED="1"
info "Full VPS bootstrap completed for ${DOMAIN}."
info "Docker image: ${IMAGE}"
printf '\n%s\n' 'Sensitive initial VPN credentials follow. Store them securely.'
printf 'VPN username: %s\n' "${VPN_USERNAME}"
printf 'VPN password: %s\n' "${GENERATED_VPN_PASSWORD}"
info 'Initial VPN credentials were written root-only to /root/ocserv-vps-initial-credentials.'
info 'Run status.sh next and test a client before closing the independent SSH session.'
