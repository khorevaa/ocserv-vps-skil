#!/usr/bin/env bash

APPROVE_RESTART="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) printf '%s\n' 'Usage: remote-rotate-ui-access.sh --approve-restart'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
[[ "${APPROVE_RESTART}" == "1" ]] || die '--approve-restart is required.'
for command in awk curl docker getent id nologin openssl stat; do require_command "${command}"; done
[[ -x "${OCSERV_UI_HOST_SHELL}" ]] || die "Required nologin shell is unavailable: ${OCSERV_UI_HOST_SHELL}"
[[ -f "${OCSERV_UI_COMPOSE_FILE}" && ! -L "${OCSERV_UI_COMPOSE_FILE}" && \
   -f "${OCSERV_UI_ENV_FILE}" && ! -L "${OCSERV_UI_ENV_FILE}" ]] || \
  die 'The managed UI files are missing or unsafe.'

ACCESS_FILE="${OCSERV_STACK_ROOT}/ui-secrets/access-secret"
ACCESS_HANDOFF="/root/ocserv-vps-ui-access"
[[ -f "${ACCESS_FILE}" ]] || die 'The managed UI access secret is missing.'
[[ ! -L "${ACCESS_FILE}" ]] || die 'The managed UI access secret must not be a symlink.'
[[ "$(stat -c '%u:%g %a' "${ACCESS_FILE}")" == '0:10001 440' ]] || \
  die 'The managed UI access secret must be root:10001 mode 0440.'

UI_LOCAL_HOST="$(awk -F= '$1 == "OCSERV_UI_LOCAL_HOST" {print substr($0, index($0, "=") + 1); exit}' "${OCSERV_UI_ENV_FILE}")"
UI_PORT="$(awk -F= '$1 == "OCSERV_UI_LOCAL_PORT" {print substr($0, index($0, "=") + 1); exit}' "${OCSERV_UI_ENV_FILE}")"
[[ "${UI_LOCAL_HOST}" =~ ^ocserv-[0-9a-f]{32}\.localhost$ ]] || \
  die 'The managed browser hostname in ui.env is missing or unsafe.'
[[ -n "${UI_PORT}" ]] || die 'Cannot determine the managed local tunnel port from ui.env.'
validate_port 'local tunnel port' "${UI_PORT}"
ui_host_identity_is_exact || die 'The reserved UI host identity is missing or unsafe.'

acquire_stack_locks

ACCESS_BACKUP="$(mktemp "${OCSERV_STACK_ROOT}/ui-secrets/access-secret.backup.XXXXXX")"
ACCESS_NEW_FILE="$(mktemp "${OCSERV_STACK_ROOT}/ui-secrets/access-secret.new.XXXXXX")"
ACCESS_REQUEST="$(mktemp /run/ocserv-vps-ui-access-request.XXXXXX)"
HANDOFF_NEW="$(mktemp /root/ocserv-vps-ui-access.XXXXXX)"
chmod 0600 "${ACCESS_BACKUP}" "${ACCESS_NEW_FILE}" "${ACCESS_REQUEST}" "${HANDOFF_NEW}"
cp "${ACCESS_FILE}" "${ACCESS_BACKUP}"
OLD_SECRET="$(<"${ACCESS_FILE}")"
NEW_SECRET="$(openssl rand -hex 32)"
printf '%s\n' "${NEW_SECRET}" > "${ACCESS_NEW_FILE}"
chown root:10001 "${ACCESS_NEW_FILE}"
chmod 0440 "${ACCESS_NEW_FILE}"

COMMITTED="0"
rollback_access_secret() {
  local rollback_failed=0
  if ! cp "${ACCESS_BACKUP}" "${ACCESS_FILE}"; then rollback_failed=1; fi
  chown root:10001 "${ACCESS_FILE}" >/dev/null 2>&1 || rollback_failed=1
  chmod 0440 "${ACCESS_FILE}" >/dev/null 2>&1 || rollback_failed=1
  compose up -d --no-deps --force-recreate ocserv-ui >/dev/null 2>&1 || rollback_failed=1
  health_check_ui_stack 60 || rollback_failed=1
  if (( rollback_failed != 0 )); then
    warn 'UI access-secret rollback failed; keep the SSH session open.'
    return 1
  fi
  warn 'Previous UI access secret was restored.'
}

on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${status}" -ne 0 && "${COMMITTED}" != "1" ]]; then
    rollback_access_secret || true
  fi
  rm -f "${ACCESS_BACKUP}" "${ACCESS_NEW_FILE}" "${ACCESS_REQUEST}" "${HANDOFF_NEW}"
  unset OLD_SECRET NEW_SECRET
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' HUP INT TERM

mv -f "${ACCESS_NEW_FILE}" "${ACCESS_FILE}"
compose up -d --no-deps --force-recreate ocserv-ui >/dev/null
health_check_ui_stack 60 || die 'UI did not become healthy over its Unix socket after access-secret rotation.'

ui_curl() {
  curl --noproxy '*' --unix-socket "${OCSERV_UI_WEB_SOCKET}" \
    --header "Host: ${UI_LOCAL_HOST}:${UI_PORT}" "$@"
}

printf '{"secret":"%s"}\n' "${OLD_SECRET}" > "${ACCESS_REQUEST}"
OLD_STATUS="$(ui_curl \
  --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --request POST --header "Origin: http://${UI_LOCAL_HOST}:${UI_PORT}" \
  --header 'Content-Type: application/json' --data-binary "@${ACCESS_REQUEST}" \
  "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/access")"
[[ "${OLD_STATUS}" == "404" ]] || die 'The previous UI access secret was not revoked.'

printf '{"secret":"%s"}\n' "${NEW_SECRET}" > "${ACCESS_REQUEST}"
NEW_STATUS="$(ui_curl \
  --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --request POST --header "Origin: http://${UI_LOCAL_HOST}:${UI_PORT}" \
  --header 'Content-Type: application/json' \
  --data-binary "@${ACCESS_REQUEST}" \
  "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/access")"
[[ "${NEW_STATUS}" == "200" ]] || die 'The new UI access secret did not create an operator session.'

cat > "${HANDOFF_NEW}" <<EOF
url=http://${UI_LOCAL_HOST}:${UI_PORT}
remote_socket=${OCSERV_UI_WEB_SOCKET}
tunnel_template=ssh -N -L 127.0.0.1:${UI_PORT}:${OCSERV_UI_WEB_SOCKET} root@<vps-host>
access_secret=${NEW_SECRET}
expires=operator session is valid for at most 12 hours
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 "${HANDOFF_NEW}"
mv -f "${HANDOFF_NEW}" "${ACCESS_HANDOFF}"

COMMITTED="1"
rm -f "${ACCESS_BACKUP}" "${ACCESS_REQUEST}"
unset OLD_SECRET NEW_SECRET
info 'UI access secret rotated; every previous operator session and secret is now invalid.'
info "Retrieve the new secret from ${ACCESS_HANDOFF}, store it securely, then delete the handoff file."
