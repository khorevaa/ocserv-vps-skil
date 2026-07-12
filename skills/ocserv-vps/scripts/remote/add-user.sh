#!/usr/bin/env bash

USERNAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --username) USERNAME="${2:-}"; shift 2 ;;
    -h|--help) printf '%s\n' 'Usage: remote-add-user.sh --username <name>'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
validate_username "${USERNAME}"
[[ -f "${OCSERV_STATE_FILE}" ]] || die 'Managed stack is missing.'
CURRENT_IMAGE="$(state_get current_image)"
docker image inspect "${CURRENT_IMAGE}" >/dev/null 2>&1 || die "Current image is missing: ${CURRENT_IMAGE}"

install -d -m 0755 "$(dirname "${OCSERV_LOCK}")"
exec 9>"${OCSERV_LOCK}"
flock -n 9 || die 'Another ocserv VPS operation is running.'

create_password_user "${CURRENT_IMAGE}" "${USERNAME}"
CREDENTIAL_FILE="/root/ocserv-vps-user-${USERNAME}"
cat > "${CREDENTIAL_FILE}" <<EOF
username=${USERNAME}
password=${GENERATED_VPN_PASSWORD}
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 "${CREDENTIAL_FILE}"
if [[ -f /root/ocserv-vps-initial-credentials ]]; then
  INITIAL_USERNAME="$(awk -F= '$1 == "username" {print substr($0, index($0, "=") + 1); exit}' /root/ocserv-vps-initial-credentials)"
  if [[ "${INITIAL_USERNAME}" == "${USERNAME}" ]]; then
    rm -f /root/ocserv-vps-initial-credentials
    info 'Removed the stale initial credential file for the rotated user.'
  fi
fi
docker kill --signal HUP "${OCSERV_CONTAINER}" >/dev/null 2>&1 || true
info "User ${USERNAME} was written to the password database."
info "Credentials were stored root-only in ${CREDENTIAL_FILE}; retrieve them securely and delete the file."
