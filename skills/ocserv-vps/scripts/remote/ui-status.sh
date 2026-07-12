#!/usr/bin/env bash

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) printf '%s\n' 'Usage: remote-ui-status.sh'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
for command in awk curl docker getent id nologin stat systemctl; do require_command "${command}"; done
[[ -x "${OCSERV_UI_HOST_SHELL}" ]] || die "Required nologin shell is unavailable: ${OCSERV_UI_HOST_SHELL}"
[[ -f "${OCSERV_UI_COMPOSE_FILE}" && ! -L "${OCSERV_UI_COMPOSE_FILE}" && \
   -f "${OCSERV_UI_ENV_FILE}" && ! -L "${OCSERV_UI_ENV_FILE}" ]] || \
  die 'The managed UI files are missing or unsafe.'
[[ -f "${OCSERV_STACK_ROOT}/ui-secrets/access-secret" ]] || die 'The managed UI access secret is missing.'
[[ ! -L "${OCSERV_STACK_ROOT}/ui-secrets/access-secret" ]] || die 'The managed UI access secret must not be a symlink.'
[[ "$(stat -c '%u:%g %a' "${OCSERV_STACK_ROOT}/ui-secrets/access-secret")" == '0:10001 440' ]] || \
  die 'The managed UI access secret must be root:10001 mode 0440.'
[[ -f "${OCSERV_UI_ACCESS_INFO_SCRIPT}" && ! -L "${OCSERV_UI_ACCESS_INFO_SCRIPT}" ]] || \
  die 'The root-only UI access-info command is missing or unsafe.'
[[ "$(stat -c '%u:%g %a' "${OCSERV_UI_ACCESS_INFO_SCRIPT}")" == '0:0 700' ]] || \
  die 'The UI access-info command must be root:root mode 0700.'

DOMAIN="$(state_get domain)"
UI_LOCAL_HOST="$(awk -F= '$1 == "OCSERV_UI_LOCAL_HOST" {print substr($0, index($0, "=") + 1); exit}' "${OCSERV_UI_ENV_FILE}")"
UI_PORT="$(awk -F= '$1 == "OCSERV_UI_LOCAL_PORT" {print substr($0, index($0, "=") + 1); exit}' "${OCSERV_UI_ENV_FILE}")"
[[ "${UI_LOCAL_HOST}" =~ ^ocserv-[0-9a-f]{32}\.localhost$ ]] || \
  die 'The managed browser hostname in ui.env is missing or unsafe.'
[[ -n "${UI_PORT}" ]] || die 'Cannot determine the managed local tunnel port from ui.env.'
validate_port 'local tunnel port' "${UI_PORT}"
ui_host_identity_is_exact || \
  die "Reserved UI host identity must be locked ${OCSERV_UI_HOST_USER} ${OCSERV_UI_HOST_UID}:${OCSERV_UI_HOST_GID}, nologin, with no extra members."

printf '%s\n' '=== UI release ==='
sed -n -E '/^(OCSERV_UI_IMAGE|OCSERV_CONTROL_IMAGE)=/p' "${OCSERV_UI_ENV_FILE}"
CONTROL_OCSERV_IMAGE="$(docker inspect --format '{{ index .Config.Labels "org.ocserv-vps.ocserv-image" }}' ocserv-vps-control 2>/dev/null || true)"
printf 'Control compatibility: expected=%s active=%s\n' "${CONTROL_OCSERV_IMAGE:-unknown}" "$(state_get current_image)"

printf '\n%s\n' '=== Containers ==='
compose ps ocserv ocserv-control ocserv-ui
for container in ocserv-vps ocserv-vps-control ocserv-vps-ui; do
  docker inspect --format 'name={{.Name}} running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} image={{.Config.Image}}' "${container}" 2>/dev/null || true
done

printf '\n%s\n' '=== Unix-socket access ==='
printf 'Browser URL after SSH forwarding: http://%s:%s (secret gate required)\n' "${UI_LOCAL_HOST}" "${UI_PORT}"
printf 'Tunnel: ssh -N -L 127.0.0.1:%s:%s root@%s\n' "${UI_PORT}" "${OCSERV_UI_WEB_SOCKET}" "${DOMAIN}"
printf 'Reserved host identity: %s uid=%s gid=%s, locked nologin, no supplementary/group members\n' \
  "${OCSERV_UI_HOST_USER}" "${OCSERV_UI_HOST_UID}" "${OCSERV_UI_HOST_GID}"
[[ -f "${OCSERV_UI_TMPFILES_FILE}" && ! -L "${OCSERV_UI_TMPFILES_FILE}" ]] || \
  die 'The UI tmpfiles rule is missing or unsafe.'
[[ "$(stat -c '%u:%g %a' "${OCSERV_UI_TMPFILES_FILE}")" == '0:0 644' ]] || \
  die 'The UI tmpfiles rule must be root:root mode 0644.'
[[ "$(<"${OCSERV_UI_TMPFILES_FILE}")" == "d ${OCSERV_UI_WEB_RUN_DIR} 0700 10001 10001 -" ]] || \
  die 'The UI tmpfiles rule does not enforce the expected runtime-directory permissions.'
[[ -d "${OCSERV_UI_WEB_RUN_DIR}" && ! -L "${OCSERV_UI_WEB_RUN_DIR}" ]] || \
  die 'The UI web runtime path is not a real directory.'
[[ "$(stat -c '%u:%g %a' "${OCSERV_UI_WEB_RUN_DIR}")" == '10001:10001 700' ]] || \
  die 'The UI web runtime directory has unexpected ownership or permissions.'
[[ -S "${OCSERV_UI_WEB_SOCKET}" && ! -L "${OCSERV_UI_WEB_SOCKET}" ]] || \
  die 'The UI web Unix socket is missing or unsafe.'
[[ "$(stat -c '%u:%g %a' "${OCSERV_UI_WEB_SOCKET}")" == '10001:10001 600' ]] || \
  die 'The UI web Unix socket has unexpected ownership or permissions.'
[[ "$(docker inspect --format '{{.HostConfig.NetworkMode}}' ocserv-vps-ui)" == 'none' ]] || \
  die 'The UI web container unexpectedly has a network namespace.'
UI_PORT_BINDINGS="$(docker inspect --format '{{json .HostConfig.PortBindings}}' ocserv-vps-ui)"
[[ "${UI_PORT_BINDINGS}" == 'null' || "${UI_PORT_BINDINGS}" == '{}' ]] || \
  die 'The UI web container unexpectedly publishes a TCP port.'
[[ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ocserv-vps-control)" == 'healthy' ]] || \
  die 'The UI control container is not healthy.'
[[ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ocserv-vps-ui)" == 'healthy' ]] || \
  die 'The UI web container is not healthy.'
docker exec ocserv-vps-ui /usr/local/bin/ocserv-ui healthcheck || die 'The UI web Unix-socket health probe failed.'
printf 'Unix socket: %s (10001:10001 mode 0600); container health: healthy\n' "${OCSERV_UI_WEB_SOCKET}"
curl --noproxy '*' --unix-socket "${OCSERV_UI_WEB_SOCKET}" \
  --header "Host: ${UI_LOCAL_HOST}:${UI_PORT}" --fail --silent --show-error \
  "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/health"
printf '\n'
LOCKED_STATUS="$(curl --noproxy '*' --unix-socket "${OCSERV_UI_WEB_SOCKET}" \
  --header "Host: ${UI_LOCAL_HOST}:${UI_PORT}" \
  --silent --show-error --output /dev/null --write-out '%{http_code}' \
  "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/auth/me")"
[[ "${LOCKED_STATUS}" == '404' ]] || die 'The management API is not hidden by the UI access gate.'
printf '%s\n' 'Secret gate: management API hidden without cookie'

printf '\n%s\n' '=== Remote ingress ==='
for legacy_path in \
  /etc/nginx/sites-available/ocserv-ui.conf \
  /etc/nginx/sites-enabled/ocserv-ui.conf \
  "${OCSERV_BIN_DIR}/apply-ui-firewall.sh" \
  /etc/systemd/system/ocserv-vps-ui-firewall.service; do
  [[ ! -e "${legacy_path}" && ! -L "${legacy_path}" ]] || \
    die "Legacy public UI ingress artifact exists: ${legacy_path}"
done
systemctl is-active --quiet ocserv-vps-ui-firewall.service && \
  die 'Legacy public UI firewall service is active.'
if command -v iptables >/dev/null 2>&1 && iptables -w -S OCSERV_UI_INPUT >/dev/null 2>&1; then
  die 'Legacy IPv4 UI ingress chain still exists.'
fi
if command -v ip6tables >/dev/null 2>&1 && ip6tables -w -S OCSERV_UI_INPUT >/dev/null 2>&1; then
  die 'Legacy IPv6 UI ingress chain still exists.'
fi
printf '%s\n' 'Remote UI ingress: none (network_mode=none, no port bindings, no nginx/firewall UI assets)'
printf '%s\n' 'ACME/nginx/firewall state: intentionally unmanaged by the UI installer'

printf '\n%s\n' '=== Credential handoff ==='
printf 'Root access-info command: %s\n' "${OCSERV_UI_ACCESS_INFO_SCRIPT}"
if [[ -f /root/ocserv-vps-ui-access ]]; then
  printf '%s\n' 'UI access secret file: /root/ocserv-vps-ui-access (mode 0600)'
else
  printf '%s\n' 'No pending UI access-secret handoff.'
fi
