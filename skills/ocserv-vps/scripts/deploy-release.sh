#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"

usage() {
  cat <<'EOF'
Usage:
  deploy-release.sh --host <ssh_target> --version <version> \
    --source-url <https_url> --sha256 <digest> \
    --signature-url <https_url> --signing-key-url <https_url> \
    --signing-key-fingerprint <full_fingerprint> --approve-restart [options]

Options:
  --config <absolute_path>                 Default: /etc/ocserv/ocserv.conf
  --adopt-existing-service <unit.service>  Required for first package migration.
  --build-jobs <count>                     Default: min(nproc, 4) on target.
  --health-timeout <seconds>               Default: 30
  --skip-package-install                   Do not apt-install build dependencies.
  --ssh-port <port>                        Default: 22
  --identity-file <path>
  --ssh-password <pass>
  --accept-new-host-key
  --approve-restart                        Required acknowledgment of disconnect.
  -h, --help
EOF
}

HOST=""
VERSION=""
SOURCE_URL=""
SHA256=""
SIGNATURE_URL=""
SIGNING_KEY_URL=""
SIGNING_KEY_FINGERPRINT=""
CONFIG="/etc/ocserv/ocserv.conf"
ADOPT_SERVICE=""
BUILD_JOBS=""
HEALTH_TIMEOUT="30"
SKIP_PACKAGE_INSTALL="0"
SSH_PORT="22"
IDENTITY_FILE=""
SSH_PASSWORD=""
ACCEPT_NEW_HOST_KEY="0"
APPROVE_RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ocserv_require_value "$1" "${2:-}"; HOST="$2"; shift 2 ;;
    --version) ocserv_require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --source-url) ocserv_require_value "$1" "${2:-}"; SOURCE_URL="$2"; shift 2 ;;
    --sha256) ocserv_require_value "$1" "${2:-}"; SHA256="$2"; shift 2 ;;
    --signature-url) ocserv_require_value "$1" "${2:-}"; SIGNATURE_URL="$2"; shift 2 ;;
    --signing-key-url) ocserv_require_value "$1" "${2:-}"; SIGNING_KEY_URL="$2"; shift 2 ;;
    --signing-key-fingerprint) ocserv_require_value "$1" "${2:-}"; SIGNING_KEY_FINGERPRINT="$2"; shift 2 ;;
    --config) ocserv_require_value "$1" "${2:-}"; CONFIG="$2"; shift 2 ;;
    --adopt-existing-service) ocserv_require_value "$1" "${2:-}"; ADOPT_SERVICE="$2"; shift 2 ;;
    --build-jobs) ocserv_require_value "$1" "${2:-}"; BUILD_JOBS="$2"; shift 2 ;;
    --health-timeout) ocserv_require_value "$1" "${2:-}"; HEALTH_TIMEOUT="$2"; shift 2 ;;
    --skip-package-install) SKIP_PACKAGE_INSTALL="1"; shift ;;
    --ssh-port) ocserv_require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
    --identity-file) ocserv_require_value "$1" "${2:-}"; IDENTITY_FILE="$2"; shift 2 ;;
    --ssh-password) ocserv_require_value "$1" "${2:-}"; SSH_PASSWORD="$2"; shift 2 ;;
    --accept-new-host-key) ACCEPT_NEW_HOST_KEY="1"; shift ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

missing=()
for pair in \
  "HOST:${HOST}" \
  "VERSION:${VERSION}" \
  "SOURCE_URL:${SOURCE_URL}" \
  "SHA256:${SHA256}" \
  "SIGNATURE_URL:${SIGNATURE_URL}" \
  "SIGNING_KEY_URL:${SIGNING_KEY_URL}" \
  "SIGNING_KEY_FINGERPRINT:${SIGNING_KEY_FINGERPRINT}"; do
  key="${pair%%:*}"
  value="${pair#*:}"
  [[ -n "${value}" ]] || missing+=("${key}")
done
if (( ${#missing[@]} > 0 )); then
  printf 'Missing required inputs: %s\n' "${missing[*]}" >&2
  usage >&2
  exit 2
fi
if [[ "${APPROVE_RESTART}" != "1" ]]; then
  printf '%s\n' 'Refusing deployment: --approve-restart is required because active VPN sessions will disconnect.' >&2
  exit 2
fi
if [[ ! "${VERSION}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]]; then
  printf 'Unsafe version value: %s\n' "${VERSION}" >&2
  exit 2
fi
if [[ ! "${SHA256}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
  printf '%s\n' '--sha256 must be exactly 64 hexadecimal characters.' >&2
  exit 2
fi
if [[ ! "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] || (( HEALTH_TIMEOUT < 5 || HEALTH_TIMEOUT > 300 )); then
  printf '%s\n' '--health-timeout must be an integer from 5 to 300.' >&2
  exit 2
fi
if [[ -n "${BUILD_JOBS}" ]] && { [[ ! "${BUILD_JOBS}" =~ ^[0-9]+$ ]] || (( BUILD_JOBS < 1 || BUILD_JOBS > 32 )); }; then
  printf '%s\n' '--build-jobs must be an integer from 1 to 32.' >&2
  exit 2
fi
ocserv_validate_ssh_port "${SSH_PORT}"

remote_args=(
  --version "${VERSION}"
  --source-url "${SOURCE_URL}"
  --sha256 "${SHA256}"
  --signature-url "${SIGNATURE_URL}"
  --signing-key-url "${SIGNING_KEY_URL}"
  --signing-key-fingerprint "${SIGNING_KEY_FINGERPRINT}"
  --config "${CONFIG}"
  --health-timeout "${HEALTH_TIMEOUT}"
  --approve-restart
)
[[ -z "${ADOPT_SERVICE}" ]] || remote_args+=(--adopt-existing-service "${ADOPT_SERVICE}")
[[ -z "${BUILD_JOBS}" ]] || remote_args+=(--build-jobs "${BUILD_JOBS}")
[[ "${SKIP_PACKAGE_INSTALL}" == "0" ]] || remote_args+=(--skip-package-install)

ocserv_run_remote \
  "${SCRIPT_DIR}/remote/deploy-release.sh" \
  "${HOST}" "${SSH_PASSWORD}" "${SSH_PORT}" "${IDENTITY_FILE}" "${ACCEPT_NEW_HOST_KEY}" \
  "${remote_args[@]}"
