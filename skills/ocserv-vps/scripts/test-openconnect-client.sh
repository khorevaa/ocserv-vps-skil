#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

usage() {
  cat <<'EOF'
Usage:
  test-openconnect-client.sh --server <fqdn> --username <name> [options]

Read the VPN password from standard input, connect with OpenConnect, require
the probe route and HTTPS request to use the tunnel, then disconnect cleanly.

Options:
  --port <port>          Default: 443
  --interface <name>    Default: oclocal0
  --probe-url <url>     Default: https://1.1.1.1/cdn-cgi/trace
  -h, --help
EOF
}

SERVER=""
USERNAME=""
PORT="443"
INTERFACE="oclocal0"
PROBE_URL="https://1.1.1.1/cdn-cgi/trace"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="${2:-}"; shift 2 ;;
    --username) USERNAME="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --interface) INTERFACE="${2:-}"; shift 2 ;;
    --probe-url) PROBE_URL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || { printf '%s\n' 'Run as root so OpenConnect can create a tunnel.' >&2; exit 1; }
[[ "${SERVER}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ && "${SERVER}" == *.* ]] || {
  printf '%s\n' 'Invalid server FQDN.' >&2
  exit 2
}
[[ "${USERNAME}" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || { printf '%s\n' 'Invalid username.' >&2; exit 2; }
[[ "${PORT}" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || { printf '%s\n' 'Invalid port.' >&2; exit 2; }
[[ "${INTERFACE}" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || { printf '%s\n' 'Invalid tunnel interface.' >&2; exit 2; }
[[ "${PROBE_URL}" == https://* ]] || { printf '%s\n' 'Probe URL must use HTTPS.' >&2; exit 2; }

for command in curl ip openconnect timeout; do
  command -v "${command}" >/dev/null 2>&1 || { printf 'Missing command: %s\n' "${command}" >&2; exit 1; }
done
[[ -e /dev/net/tun ]] || { printf '%s\n' '/dev/net/tun is unavailable.' >&2; exit 1; }
ip link show "${INTERFACE}" >/dev/null 2>&1 && { printf 'Interface already exists: %s\n' "${INTERFACE}" >&2; exit 1; }

PASSWORD_FILE="$(mktemp /run/ocserv-vps-local-password.XXXXXX)"
PID_FILE="/run/ocserv-vps-local-openconnect.$$.pid"

cleanup() {
  local status=$?
  set +e
  if [[ -s "${PID_FILE}" ]]; then
    CLIENT_PID="$(cat "${PID_FILE}")"
    kill -TERM "${CLIENT_PID}" >/dev/null 2>&1
    for _ in 1 2 3 4 5; do
      kill -0 "${CLIENT_PID}" >/dev/null 2>&1 || break
      sleep 1
    done
    kill -KILL "${CLIENT_PID}" >/dev/null 2>&1
  fi
  rm -f "${PASSWORD_FILE}" "${PID_FILE}"
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

IFS= read -r PASSWORD || { printf '%s\n' 'VPN password was not provided on stdin.' >&2; exit 2; }
[[ -n "${PASSWORD}" ]] || { printf '%s\n' 'VPN password is empty.' >&2; exit 2; }
printf '%s\n' "${PASSWORD}" > "${PASSWORD_FILE}"
unset PASSWORD

env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u https_proxy -u http_proxy \
  timeout --signal=TERM --kill-after=5s 60s \
  openconnect \
    --protocol=anyconnect \
    --interface="${INTERFACE}" \
    --user="${USERNAME}" \
    --passwd-on-stdin \
    --non-inter \
    --background \
    --pid-file="${PID_FILE}" \
    "https://${SERVER}:${PORT}" < "${PASSWORD_FILE}"

[[ -s "${PID_FILE}" ]] || { printf '%s\n' 'OpenConnect did not create a PID file.' >&2; exit 1; }
kill -0 "$(cat "${PID_FILE}")"

ROUTE_DEVICE=""
for _ in $(seq 1 20); do
  ROUTE_DEVICE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
  [[ "${ROUTE_DEVICE}" == "${INTERFACE}" ]] && break
  sleep 1
done
[[ "${ROUTE_DEVICE}" == "${INTERFACE}" ]] || {
  printf 'Route to 1.1.1.1 does not use %s: %s\n' "${INTERFACE}" "${ROUTE_DEVICE:-missing}" >&2
  exit 1
}

PROBE_OUTPUT="$(env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u https_proxy -u http_proxy \
  curl --noproxy '*' --interface "${INTERFACE}" --fail --silent --show-error --max-time 20 "${PROBE_URL}")"
grep -q '^ip=' <<<"${PROBE_OUTPUT}" || { printf '%s\n' 'HTTPS probe did not return a client IP.' >&2; exit 1; }

printf 'Local OpenConnect test passed: server=%s:%s interface=%s route=%s\n' \
  "${SERVER}" "${PORT}" "${INTERFACE}" "${ROUTE_DEVICE}"
