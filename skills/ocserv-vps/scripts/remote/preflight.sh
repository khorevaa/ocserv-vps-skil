#!/usr/bin/env bash

DOMAIN=""
TARGET_VERSION=""
VPN_PORT="443"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --target-version) TARGET_VERSION="${2:-}"; shift 2 ;;
    --vpn-port) VPN_PORT="${2:-}"; shift 2 ;;
    -h|--help) printf '%s\n' 'Usage: remote-preflight.sh [--domain fqdn] [--target-version version] [--vpn-port port]'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
validate_port 'VPN port' "${VPN_PORT}"
[[ -z "${DOMAIN}" ]] || validate_domain "${DOMAIN}"
[[ -z "${TARGET_VERSION}" ]] || validate_version "${TARGET_VERSION}"

printf '%s\n' '=== Host ==='
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  printf 'OS: %s\n' "${PRETTY_NAME:-unknown}"
else
  printf '%s\n' 'OS: unknown (/etc/os-release missing)'
fi
printf 'Kernel: %s\n' "$(uname -srmo)"
printf 'Architecture: %s\n' "$(dpkg --print-architecture 2>/dev/null || uname -m)"
printf 'Memory: '
awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%.1f GiB available of %.1f GiB\n", a/1048576, t/1048576}' /proc/meminfo
printf 'Disk under /opt: '
df -hP /opt 2>/dev/null | awk 'NR == 2 {print $4 " available of " $2}' || df -hP / | awk 'NR == 2 {print $4 " available of " $2}'
printf '/dev/net/tun: %s\n' "$(if [[ -e /dev/net/tun ]]; then printf present; else printf MISSING; fi)"
printf 'Default interface: %s\n' "$(ip -4 route show default 2>/dev/null | awk 'NR == 1 {print $5}')"

printf '\n%s\n' '=== Docker ==='
if command -v docker >/dev/null 2>&1; then
  docker --version || true
  docker compose version 2>/dev/null || printf '%s\n' 'Compose v2: MISSING'
  systemctl is-active docker 2>/dev/null || true
else
  printf '%s\n' 'Docker: absent (bootstrap will install it)'
fi

printf '\n%s\n' '=== Network and ports ==='
printf 'IPv4 forwarding: %s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf unknown)"
printf 'TCP %s listening: ' "${VPN_PORT}"
if listener_exists tcp "${VPN_PORT}"; then printf 'yes\n'; else printf 'no\n'; fi
printf 'UDP %s listening: ' "${VPN_PORT}"
if listener_exists udp "${VPN_PORT}"; then printf 'yes\n'; else printf 'no\n'; fi
printf 'TCP 80 listening: '
if listener_exists tcp 80; then printf 'yes\n'; else printf 'no\n'; fi
if iptables -w -S OCSERV_VPS_INPUT >/dev/null 2>&1; then
  printf '%s\n' 'Managed firewall chain: present'
else
  printf '%s\n' 'Managed firewall chain: absent'
fi

printf '\n%s\n' '=== Domain and certificate ==='
if [[ -n "${DOMAIN}" ]]; then
  printf 'Domain: %s\n' "${DOMAIN}"
  getent ahostsv4 "${DOMAIN}" | awk '{print "  " $1}' | sort -u || printf '%s\n' '  no IPv4 resolution'
  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -subject -issuer -dates 2>/dev/null || true
  else
    printf '%s\n' 'Certificate: absent'
  fi
else
  printf '%s\n' 'No domain supplied.'
fi

printf '\n%s\n' '=== Managed stack ==='
if [[ -f "${OCSERV_STATE_FILE}" ]]; then
  sed -n '1,80p' "${OCSERV_STATE_FILE}"
  if command -v docker >/dev/null 2>&1; then
    docker inspect --format 'Container running={{.State.Running}} image={{.Config.Image}} id={{.Image}}' "${OCSERV_CONTAINER}" 2>/dev/null || printf '%s\n' 'Container: absent'
  fi
else
  printf '%s\n' 'Managed state: absent (fresh bootstrap available)'
fi

if [[ -n "${TARGET_VERSION}" ]]; then
  printf '\nTarget version %s retained image metadata:\n' "${TARGET_VERSION}"
  grep -l -F "version=${TARGET_VERSION}" "${OCSERV_IMAGE_ROOT}"/*/metadata 2>/dev/null || printf '%s\n' '  none'
fi

printf '\n%s\n' 'Preflight is read-only. Bootstrap requires explicit firewall and restart approvals.'
