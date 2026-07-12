#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 027

OCSERV_STACK_ROOT="/opt/ocserv-vps"
OCSERV_CONFIG_DIR="${OCSERV_STACK_ROOT}/config"
OCSERV_COMPOSE_FILE="${OCSERV_STACK_ROOT}/compose.yaml"
OCSERV_ENV_FILE="${OCSERV_STACK_ROOT}/stack.env"
OCSERV_STATE_FILE="${OCSERV_STACK_ROOT}/state"
OCSERV_IMAGE_ROOT="${OCSERV_STACK_ROOT}/images"
OCSERV_BIN_DIR="${OCSERV_STACK_ROOT}/bin"
OCSERV_BACKUP_ROOT="/var/backups/ocserv-vps"
OCSERV_LOCK="/run/lock/ocserv-vps.lock"
OCSERV_CONTAINER="ocserv-vps"
OCSERV_NETWORK_SCRIPT="${OCSERV_BIN_DIR}/apply-network.sh"
OCSERV_NETWORK_SERVICE="/etc/systemd/system/ocserv-vps-network.service"

info() { printf '[ocserv-vps] %s\n' "$*"; }
warn() { printf '[ocserv-vps] WARNING: %s\n' "$*" >&2; }
die() { printf '[ocserv-vps] ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { [[ "${EUID}" -eq 0 ]] || die 'Run the remote script as root.'; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

validate_version() {
  [[ "$1" =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] || die "Unsafe version value: $1"
}

validate_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ && "$1" == *.* ]] || die "Invalid public domain: $1"
}

validate_username() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || die "Unsafe username: $1"
}

validate_port() {
  local label="$1" value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )) || die "Invalid ${label}: ${value}"
}

validate_registry_image() {
  [[ "$1" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || \
    die 'Image must be ghcr.io/<owner>/<image>:<version> without a digest.'
}

validate_ipv4_cidr() {
  require_command python3
  python3 - "$1" <<'PY'
import ipaddress
import sys
network = ipaddress.ip_network(sys.argv[1], strict=True)
if network.version != 4 or network.prefixlen < 8:
    raise SystemExit(1)
PY
}

validate_interface() {
  [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,32}$ ]] || die "Unsafe interface name: $1"
}

state_get() {
  local key="$1"
  [[ -f "${OCSERV_STATE_FILE}" ]] || return 0
  awk -F= -v wanted="${key}" '$1 == wanted {print substr($0, index($0, "=") + 1)}' "${OCSERV_STATE_FILE}" | tail -n 1
}

write_state() {
  local current_version="$1" current_image="$2" previous_version="$3" previous_image="$4"
  local domain="$5" vpn_network="$6" vpn_port="$7" source_sha256="$8" last_backup="$9"
  local temp
  install -d -m 0750 "${OCSERV_STACK_ROOT}"
  temp="$(mktemp "${OCSERV_STACK_ROOT}/state.XXXXXX")"
  cat > "${temp}" <<EOF
current_version=${current_version}
current_image=${current_image}
previous_version=${previous_version}
previous_image=${previous_image}
domain=${domain}
vpn_network=${vpn_network}
vpn_port=${vpn_port}
source_sha256=${source_sha256}
last_backup=${last_backup}
openconnect_checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 0640 "${temp}"
  mv -f "${temp}" "${OCSERV_STATE_FILE}"
}

write_stack_env() {
  local temp
  temp="$(mktemp "${OCSERV_STACK_ROOT}/stack.env.XXXXXX")"
  printf 'OCSERV_IMAGE=%s\n' "$1" > "${temp}"
  chmod 0640 "${temp}"
  mv -f "${temp}" "${OCSERV_ENV_FILE}"
}

compose() {
  docker compose --project-directory "${OCSERV_STACK_ROOT}" --env-file "${OCSERV_ENV_FILE}" -f "${OCSERV_COMPOSE_FILE}" "$@"
}

render_compose_file() {
  install -d -m 0750 "${OCSERV_STACK_ROOT}"
  cat > "${OCSERV_COMPOSE_FILE}" <<'EOF'
services:
  ocserv:
    image: ${OCSERV_IMAGE}
    container_name: ocserv-vps
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./config:/etc/ocserv:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    tmpfs:
      - /run/ocserv:mode=0755
    restart: unless-stopped
    stop_grace_period: 45s
    healthcheck:
      test: ["CMD", "/usr/local/sbin/ocserv", "--version"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
EOF
  chmod 0640 "${OCSERV_COMPOSE_FILE}"
}

install_docker_engine() {
  if command -v docker >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    if docker compose version >/dev/null 2>&1; then
      info 'Existing Docker Engine and Compose v2 detected; installation skipped.'
      return 0
    fi
    info 'Existing Docker Engine detected; installing only the missing Compose v2 plugin.'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
      apt-get install -y --no-install-recommends docker-compose-plugin
    elif apt-cache show docker-compose-v2 >/dev/null 2>&1; then
      apt-get install -y --no-install-recommends docker-compose-v2
    else
      die 'Docker exists but Compose v2 is missing and no plugin package is available. Install Compose v2 without replacing Docker, then rerun.'
    fi
    docker compose version >/dev/null 2>&1 || die 'Compose v2 is still unavailable.'
    return 0
  fi

  [[ -r /etc/os-release ]] || die '/etc/os-release is unavailable.'
  local docker_os_id docker_os_codename
  docker_os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
  docker_os_codename="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")"
  case "${docker_os_id}" in debian|ubuntu) ;; *) die "Unsupported Docker host: ${docker_os_id:-unknown}" ;; esac
  [[ -n "${docker_os_codename}" ]] || die 'VERSION_CODENAME is missing.'

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg
  local conflicting=() package
  for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    if dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q 'install ok installed'; then conflicting+=("${package}"); fi
  done
  if (( ${#conflicting[@]} > 0 )); then
    info "Removing packages that conflict with a new Docker Engine installation: ${conflicting[*]}"
    apt-get remove -y "${conflicting[@]}"
  fi
  install -d -m 0755 /etc/apt/keyrings
  curl --proto '=https' --tlsv1.2 --fail --location "https://download.docker.com/linux/${docker_os_id}/gpg" --output /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${docker_os_id}
Suites: ${docker_os_codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker version >/dev/null
  docker compose version >/dev/null
}

pull_verified_image() {
  local image="$1" expected_version="$2"
  validate_registry_image "${image}"
  validate_version "${expected_version}"
  docker pull "${image}"
  local actual_version source_sha base_image image_id short_sha metadata_dir
  actual_version="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "${image}")"
  source_sha="$(docker image inspect --format '{{ index .Config.Labels "org.ocserv-vps.source-sha256" }}' "${image}")"
  base_image="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.base.name" }}' "${image}")"
  image_id="$(docker image inspect --format '{{.Id}}' "${image}")"
  [[ "${actual_version}" == "${expected_version}" ]] || die "Image version label is ${actual_version}; expected ${expected_version}."
  [[ "${source_sha}" =~ ^[0-9a-f]{64}$ ]] || die 'Image has no valid source SHA-256 label.'
  [[ "${base_image}" =~ @sha256:[0-9A-Fa-f]{64}$ ]] || die 'Image has no immutable base-image label.'
  short_sha="${source_sha:0:12}"
  metadata_dir="${OCSERV_IMAGE_ROOT}/${expected_version}-${short_sha}"
  install -d -m 0750 "${metadata_dir}"
  cat > "${metadata_dir}/metadata" <<EOF
version=${actual_version}
image=${image}
image_id=${image_id}
source_sha256=${source_sha}
base_image=${base_image}
pulled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 0640 "${metadata_dir}/metadata"
  RESOLVED_IMAGE="${image}"
  RESOLVED_SOURCE_SHA="${source_sha}"
  info "Pulled verified GHCR image ${image}."
}

test_image_config() {
  local image="$1" help_text
  help_text="$(docker run --rm --entrypoint /usr/local/sbin/ocserv "${image}" --help 2>&1 || true)"
  local -a mounts=(-v "${OCSERV_CONFIG_DIR}:/etc/ocserv:ro" -v "/etc/letsencrypt:/etc/letsencrypt:ro")
  if grep -q -- '--test-config' <<<"${help_text}"; then
    docker run --rm --network none --entrypoint /usr/local/sbin/ocserv "${mounts[@]}" "${image}" --test-config --config=/etc/ocserv/ocserv.conf
  elif grep -Eq '(^|[[:space:],])-t([[:space:],]|$)' <<<"${help_text}"; then
    docker run --rm --network none --entrypoint /usr/local/sbin/ocserv "${mounts[@]}" "${image}" -t -c /etc/ocserv/ocserv.conf
  else
    die "Image ${image} does not advertise a config-test option."
  fi
}

listener_exists() {
  local protocol="$1" port="$2" flag
  case "${protocol}" in tcp) flag='-ltn' ;; udp) flag='-lun' ;; *) return 2 ;; esac
  ss -H "${flag}" | awk -v wanted="${port}" '{endpoint=$4; gsub(/\[/,"",endpoint); gsub(/\]/,"",endpoint); n=split(endpoint,p,":"); if (p[n] == wanted) found=1} END {exit(found ? 0 : 1)}'
}

health_check_stack() {
  local expected_image="$1" vpn_port="$2" timeout_seconds="$3"
  local expected_id actual_id deadline
  expected_id="$(docker image inspect --format '{{.Id}}' "${expected_image}")"
  deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if [[ "$(docker inspect --format '{{.State.Running}}' "${OCSERV_CONTAINER}" 2>/dev/null || true)" == "true" ]]; then
      actual_id="$(docker inspect --format '{{.Image}}' "${OCSERV_CONTAINER}" 2>/dev/null || true)"
      if [[ "${actual_id}" == "${expected_id}" ]] && listener_exists tcp "${vpn_port}" && listener_exists udp "${vpn_port}" && \
        docker exec "${OCSERV_CONTAINER}" /usr/local/sbin/ocserv --version >/dev/null 2>&1; then
        info "Health check passed for ${expected_image}: TCP and UDP ${vpn_port} are listening."
        return 0
      fi
    fi
    sleep 1
  done
  warn "Health check failed for ${expected_image}."
  docker inspect "${OCSERV_CONTAINER}" 2>/dev/null | sed -n '1,120p' >&2 || true
  docker logs --tail 100 "${OCSERV_CONTAINER}" 2>&1 >&2 || true
  return 1
}

render_ocserv_config() {
  local domain="$1" vpn_network="$2" vpn_port="$3" dns_primary="$4" dns_secondary="$5"
  install -d -m 0750 "${OCSERV_CONFIG_DIR}"
  cat > "${OCSERV_CONFIG_DIR}/ocserv.conf" <<EOF
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
tcp-port = ${vpn_port}
udp-port = ${vpn_port}
listen-host = 0.0.0.0
run-as-user = ocserv
run-as-group = ocserv
socket-file = /run/ocserv/ocserv.sock
occtl-socket-file = /run/ocserv/occtl.sock
server-cert = /etc/letsencrypt/live/${domain}/fullchain.pem
server-key = /etc/letsencrypt/live/${domain}/privkey.pem
isolate-workers = true
max-clients = 64
max-same-clients = 4
rate-limit-ms = 100
keepalive = 300
dpd = 60
mobile-dpd = 300
try-mtu-discovery = true
compression = false
auth-timeout = 240
min-reauth-time = 300
max-ban-score = 80
ban-reset-time = 300
cookie-timeout = 86400
deny-roaming = false
rekey-time = 172800
rekey-method = ssl
use-occtl = true
device = vpns
predictable-ips = true
ipv4-network = ${vpn_network}
dns = ${dns_primary}
dns = ${dns_secondary}
route = default
tunnel-all-dns = true
cisco-client-compat = true
EOF
  chmod 0640 "${OCSERV_CONFIG_DIR}/ocserv.conf"
}

create_password_user() {
  local image="$1" username="$2" password
  validate_username "${username}"
  password="$(openssl rand -hex 16)"
  install -d -m 0750 "${OCSERV_CONFIG_DIR}"
  touch "${OCSERV_CONFIG_DIR}/ocpasswd"
  chmod 0600 "${OCSERV_CONFIG_DIR}/ocpasswd"
  printf '%s\n%s\n' "${password}" "${password}" | docker run --rm -i --entrypoint /usr/local/bin/ocpasswd \
    -v "${OCSERV_CONFIG_DIR}:/etc/ocserv" "${image}" -c /etc/ocserv/ocpasswd "${username}"
  chmod 0600 "${OCSERV_CONFIG_DIR}/ocpasswd"
  GENERATED_VPN_PASSWORD="${password}"
}

delete_password_user() {
  local image="$1" username="$2"
  validate_username "${username}"
  docker run --rm --entrypoint /usr/local/bin/ocpasswd \
    -v "${OCSERV_CONFIG_DIR}:/etc/ocserv" "${image}" \
    -c /etc/ocserv/ocpasswd -d "${username}"
}

ensure_openconnect_probe_tools() {
  local -a missing=()
  local tool help_text script_candidate
  for tool in openconnect curl ip timeout; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done
  if (( ${#missing[@]} > 0 )); then
    info "Installing missing OpenConnect probe tools: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 openconnect vpnc-scripts
  fi
  for tool in openconnect curl ip timeout; do require_command "${tool}"; done
  help_text="$(openconnect --help 2>&1 || true)"
  for tool in --background --interface --non-inter --passwd-on-stdin --pid-file --resolve --script; do
    grep -q -- "${tool}" <<<"${help_text}" || die "Installed openconnect does not advertise ${tool}."
  done
  OPENCONNECT_VPNC_SCRIPT=""
  for script_candidate in /usr/share/vpnc-scripts/vpnc-script /etc/vpnc/vpnc-script; do
    if [[ -x "${script_candidate}" ]]; then OPENCONNECT_VPNC_SCRIPT="${script_candidate}"; break; fi
  done
  [[ -n "${OPENCONNECT_VPNC_SCRIPT}" ]] || die 'vpnc-script is unavailable after installing vpnc-scripts.'
}

verify_openconnect_data_path() (
  set -euo pipefail
  local domain="$1" vpn_port="$2" username="$3" password="$4"
  local resolved_ip server_ip suffix namespace host_interface peer_interface
  local password_file script_file pid_file probe_network

  validate_domain "${domain}"
  validate_port 'VPN port' "${vpn_port}"
  validate_username "${username}"
  [[ -n "${password}" ]] || die 'OpenConnect probe password is empty.'
  ensure_openconnect_probe_tools

  resolved_ip="$(getent ahostsv4 "${domain}" | awk '$2 == "STREAM" {print $1; exit}')"
  [[ -n "${resolved_ip}" ]] || die "Cannot resolve ${domain} to IPv4 for the OpenConnect probe."
  validate_ipv4_cidr "${resolved_ip}/32" || die "Resolved address is not valid IPv4: ${resolved_ip}"
  server_ip="$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
  [[ -n "${server_ip}" ]] || die 'Cannot determine the VPS IPv4 address for the OpenConnect probe.'
  validate_ipv4_cidr "${server_ip}/32" || die "Resolved address is not valid IPv4: ${server_ip}"

  suffix="$(openssl rand -hex 3)"
  namespace="ocsv-${suffix}"
  host_interface="ocvh${suffix}"
  peer_interface="ocvn${suffix}"
  probe_network='198.18.0.0/30'
  password_file="/run/ocserv-vps-openconnect-${suffix}.password"
  script_file="${OCSERV_BIN_DIR}/openconnect-${suffix}-vpnc-script"
  pid_file="/run/ocserv-vps-openconnect-${suffix}.pid"

  cleanup_probe() {
    local status=$?
    set +e
    ip netns del "${namespace}" >/dev/null 2>&1
    ip link del "${host_interface}" >/dev/null 2>&1
    rm -f "${password_file}" "${script_file}" "${pid_file}"
    exit "${status}"
  }
  trap cleanup_probe EXIT
  trap 'exit 130' HUP INT TERM

  (umask 077; printf '%s\n' "${password}" > "${password_file}")
  cat > "${script_file}" <<EOF
#!/bin/sh
unset INTERNAL_IP4_DNS INTERNAL_IP6_DNS CISCO_DEF_DOMAIN CISCO_SPLIT_DNS
exec '${OPENCONNECT_VPNC_SCRIPT}' "\$@"
EOF
  chmod 0600 "${password_file}"
  chmod 0700 "${script_file}"

  ip netns add "${namespace}"
  ip link add "${host_interface}" type veth peer name "${peer_interface}"
  ip link set "${peer_interface}" netns "${namespace}"
  ip address add 198.18.0.1/30 dev "${host_interface}"
  ip link set "${host_interface}" up
  ip netns exec "${namespace}" ip link set lo up
  ip netns exec "${namespace}" ip address add 198.18.0.2/30 dev "${peer_interface}"
  ip netns exec "${namespace}" ip link set "${peer_interface}" up
  ip netns exec "${namespace}" ip route add default via 198.18.0.1

  ip netns exec "${namespace}" timeout --signal=TERM --kill-after=5s 75s bash -c '
      set -euo pipefail
      domain="$1"
      vpn_port="$2"
      username="$3"
      server_ip="$4"
      password_file="$5"
      script_file="$6"
      pid_file="$7"

      cleanup_client() {
        set +e
        if [[ -s "${pid_file}" ]]; then
          client_pid="$(cat "${pid_file}")"
          kill -TERM "${client_pid}" >/dev/null 2>&1
          for _ in 1 2 3 4 5; do
            kill -0 "${client_pid}" >/dev/null 2>&1 || break
            sleep 1
          done
          kill -KILL "${client_pid}" >/dev/null 2>&1
        fi
        rm -f "${pid_file}"
      }
      trap cleanup_client EXIT
      trap "exit 130" HUP INT TERM

      env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u https_proxy -u http_proxy \
        openconnect \
          --protocol=anyconnect \
          --interface=ocprobe0 \
          --user="${username}" \
          --passwd-on-stdin \
          --non-inter \
          --background \
          --pid-file="${pid_file}" \
          --script="${script_file}" \
          --resolve="${domain}:${server_ip}" \
          "https://${domain}:${vpn_port}" < "${password_file}"

      [[ -s "${pid_file}" ]] || { printf "%s\n" "OpenConnect did not create a PID file." >&2; exit 1; }
      kill -0 "$(cat "${pid_file}")"

      route_device=""
      for _ in $(seq 1 20); do
        route_device="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '\''{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'\'')"
        [[ "${route_device}" == "ocprobe0" ]] && break
        sleep 1
      done
      [[ "${route_device}" == "ocprobe0" ]] || { printf "Route to 1.1.1.1 does not use the OpenConnect tunnel: %s\n" "${route_device:-missing}" >&2; exit 1; }

      probe_output="$(env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u https_proxy -u http_proxy \
        curl --noproxy "*" --interface ocprobe0 --fail --silent --show-error --max-time 20 \
          https://1.1.1.1/cdn-cgi/trace)"
      grep -q "^ip=" <<<"${probe_output}" || { printf "%s\n" "HTTPS probe did not return a client IP." >&2; exit 1; }
    ' _ "${domain}" "${vpn_port}" "${username}" "${server_ip}" "${password_file}" "${script_file}" "${pid_file}"

  info "Mandatory OpenConnect authentication and tunneled HTTPS probe passed for ${domain}:${vpn_port}."
)

render_network_assets() {
  local vpn_network="$1" vpn_port="$2" ssh_port="$3" public_interface="$4"
  validate_interface "${public_interface}"
  install -d -m 0750 "${OCSERV_BIN_DIR}"
  cat > "${OCSERV_NETWORK_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
VPN_NETWORK='${vpn_network}'
VPN_PORT='${vpn_port}'
SSH_PORT='${ssh_port}'
PUBLIC_INTERFACE='${public_interface}'
iptables -w -N OCSERV_VPS_INPUT 2>/dev/null || true
iptables -w -F OCSERV_VPS_INPUT
iptables -w -A OCSERV_VPS_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -i lo -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -p tcp --dport "\${SSH_PORT}" -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -p tcp --dport 80 -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -p tcp --dport "\${VPN_PORT}" -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -p udp --dport "\${VPN_PORT}" -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -p icmp -j ACCEPT
iptables -w -A OCSERV_VPS_INPUT -j DROP
iptables -w -C INPUT -j OCSERV_VPS_INPUT 2>/dev/null || iptables -w -I INPUT 1 -j OCSERV_VPS_INPUT
iptables -w -N OCSERV_VPS_FORWARD 2>/dev/null || true
iptables -w -F OCSERV_VPS_FORWARD
iptables -w -A OCSERV_VPS_FORWARD -s "\${VPN_NETWORK}" -o "\${PUBLIC_INTERFACE}" -j ACCEPT
iptables -w -A OCSERV_VPS_FORWARD -d "\${VPN_NETWORK}" -i "\${PUBLIC_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -w -A OCSERV_VPS_FORWARD -j RETURN
iptables -w -C FORWARD -j OCSERV_VPS_FORWARD 2>/dev/null || iptables -w -I FORWARD 1 -j OCSERV_VPS_FORWARD
iptables -w -t nat -N OCSERV_VPS_NAT 2>/dev/null || true
iptables -w -t nat -F OCSERV_VPS_NAT
iptables -w -t nat -A OCSERV_VPS_NAT -s "\${VPN_NETWORK}" -o "\${PUBLIC_INTERFACE}" -j MASQUERADE
iptables -w -t nat -A OCSERV_VPS_NAT -j RETURN
iptables -w -t nat -C POSTROUTING -j OCSERV_VPS_NAT 2>/dev/null || iptables -w -t nat -I POSTROUTING 1 -j OCSERV_VPS_NAT
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -w -N OCSERV_VPS_INPUT 2>/dev/null || true
  ip6tables -w -F OCSERV_VPS_INPUT
  ip6tables -w -A OCSERV_VPS_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -w -A OCSERV_VPS_INPUT -i lo -j ACCEPT
  ip6tables -w -A OCSERV_VPS_INPUT -p tcp --dport "\${SSH_PORT}" -j ACCEPT
  ip6tables -w -A OCSERV_VPS_INPUT -p tcp --dport 80 -j ACCEPT
  ip6tables -w -A OCSERV_VPS_INPUT -p ipv6-icmp -j ACCEPT
  ip6tables -w -A OCSERV_VPS_INPUT -j DROP
  ip6tables -w -C INPUT -j OCSERV_VPS_INPUT 2>/dev/null || ip6tables -w -I INPUT 1 -j OCSERV_VPS_INPUT
fi
EOF
  chmod 0750 "${OCSERV_NETWORK_SCRIPT}"
  cat > /etc/sysctl.d/99-ocserv-vps.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  cat > "${OCSERV_NETWORK_SERVICE}" <<EOF
[Unit]
Description=ocserv VPS forwarding, NAT and ingress firewall
Wants=network-online.target docker.service
After=network-online.target docker.service
[Service]
Type=oneshot
ExecStart=${OCSERV_NETWORK_SCRIPT}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${OCSERV_NETWORK_SERVICE}"
  systemctl daemon-reload
  sysctl --system >/dev/null
  systemctl enable --now ocserv-vps-network.service
}

create_stack_backup() {
  local label="$1" timestamp backup path
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${OCSERV_BACKUP_ROOT}/${timestamp}-${label}"
  install -d -m 0700 "${backup}"
  for path in "${OCSERV_ENV_FILE}" "${OCSERV_STATE_FILE}" "${OCSERV_COMPOSE_FILE}"; do [[ ! -f "${path}" ]] || cp -a "${path}" "${backup}/"; done
  [[ ! -d "${OCSERV_CONFIG_DIR}" ]] || tar -C "${OCSERV_STACK_ROOT}" -cpf "${backup}/config.tar" config
  LAST_BACKUP="${backup}"
}
