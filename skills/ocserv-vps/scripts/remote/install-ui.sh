#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage: remote-install-ui.sh --ui-version <version>
  --ui-image <ghcr.io/owner/image:version>
  --control-image <ghcr.io/owner/image:version>
  --ui-port <port> --ssh-port <port>
  --approve-restart
EOF
}

UI_VERSION=""
UI_IMAGE=""
CONTROL_IMAGE=""
UI_PORT="8765"
SSH_PORT="22"
APPROVE_RESTART="0"
UI_DATA_DIR="${OCSERV_STACK_ROOT}/ui-data"
UI_SECRETS_DIR="${OCSERV_STACK_ROOT}/ui-secrets"
UI_PUBLIC_DIR="${OCSERV_STACK_ROOT}/ui-public"
UI_LOCK_DIR="${OCSERV_STACK_ROOT}/locks"
UI_WEB_RUN_DIR="${OCSERV_UI_WEB_RUN_DIR}"
UI_WEB_SOCKET="${OCSERV_UI_WEB_SOCKET}"
UI_TMPFILES_FILE="${OCSERV_UI_TMPFILES_FILE}"
UI_ACCESS_HANDOFF="/root/ocserv-vps-ui-access"
LEGACY_UI_NGINX_SITE="/etc/nginx/sites-available/ocserv-ui.conf"
LEGACY_UI_NGINX_LINK="/etc/nginx/sites-enabled/ocserv-ui.conf"
LEGACY_UI_FIREWALL_SCRIPT="${OCSERV_BIN_DIR}/apply-ui-firewall.sh"
LEGACY_UI_FIREWALL_SERVICE="/etc/systemd/system/ocserv-vps-ui-firewall.service"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ui-version) UI_VERSION="${2:-}"; shift 2 ;;
    --ui-image) UI_IMAGE="${2:-}"; shift 2 ;;
    --control-image) CONTROL_IMAGE="${2:-}"; shift 2 ;;
    --ui-port) UI_PORT="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
for value in UI_VERSION UI_IMAGE CONTROL_IMAGE; do
  [[ -n "${!value}" ]] || die "Required value is missing: ${value}"
done
[[ "${APPROVE_RESTART}" == "1" ]] || die '--approve-restart is required.'
validate_version "${UI_VERSION}"
validate_registry_image "${UI_IMAGE}"
validate_registry_image "${CONTROL_IMAGE}"
[[ "${UI_IMAGE}" == "ghcr.io/khorevaa/ocserv-vps-ui:${UI_VERSION}" ]] || \
  die 'Unexpected UI image repository or tag.'
[[ "${CONTROL_IMAGE}" == "ghcr.io/khorevaa/ocserv-vps-control:${UI_VERSION}" ]] || \
  die 'Unexpected control image repository or tag.'
validate_port 'local tunnel port' "${UI_PORT}"
validate_port 'SSH port' "${SSH_PORT}"
for command in \
  awk curl docker flock getent groupadd groupdel id nologin openssl passwd \
  python3 stat systemctl systemd-tmpfiles useradd userdel; do
  require_command "${command}"
done
[[ -x "${OCSERV_UI_HOST_SHELL}" ]] || die "Required nologin shell is unavailable: ${OCSERV_UI_HOST_SHELL}"
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is unavailable.'

acquire_stack_locks

[[ -f "${OCSERV_STATE_FILE}" && -f "${OCSERV_COMPOSE_FILE}" && -f "${OCSERV_ENV_FILE}" ]] || die 'Managed stack is missing.'
[[ ! -e "${OCSERV_UI_COMPOSE_FILE}" && ! -L "${OCSERV_UI_COMPOSE_FILE}" && \
   ! -e "${OCSERV_UI_ENV_FILE}" && ! -L "${OCSERV_UI_ENV_FILE}" ]] || \
  die 'The MVP installer supports first-time UI installation only and refuses dangling managed-state symlinks.'
for path in \
  "${UI_DATA_DIR}" "${UI_SECRETS_DIR}" "${UI_PUBLIC_DIR}" \
  "${UI_WEB_RUN_DIR}" "${UI_TMPFILES_FILE}" \
  "${OCSERV_UI_ACTION_TMPFILES_FILE}" \
  "${OCSERV_UI_RESTART_PATH_UNIT}" "${OCSERV_UI_RESTART_SERVICE_UNIT}" \
  "${OCSERV_UI_ACCESS_INFO_SCRIPT}" \
  "${UI_ACCESS_HANDOFF}" \
  "${LEGACY_UI_NGINX_SITE}" "${LEGACY_UI_NGINX_LINK}" \
  "${LEGACY_UI_FIREWALL_SCRIPT}" "${LEGACY_UI_FIREWALL_SERVICE}"; do
  [[ ! -e "${path}" && ! -L "${path}" ]] || die "Refusing to overwrite existing UI state: ${path}"
done
systemctl is-active --quiet ocserv-vps-ui-firewall.service && \
  die 'Refusing to proceed while the legacy public UI firewall service is active.'
if command -v iptables >/dev/null 2>&1 && iptables -S OCSERV_UI_INPUT >/dev/null 2>&1; then
  die 'Refusing to proceed while the legacy IPv4 UI ingress chain exists; remove it only through an explicitly approved firewall operation.'
fi
if command -v ip6tables >/dev/null 2>&1 && ip6tables -S OCSERV_UI_INPUT >/dev/null 2>&1; then
  die 'Refusing to proceed while the legacy IPv6 UI ingress chain exists; remove it only through an explicitly approved firewall operation.'
fi
ui_host_identity_is_absent || \
  die "Refusing host identity collision: ${OCSERV_UI_HOST_USER} or UID/GID ${OCSERV_UI_HOST_UID} is already allocated."

DOMAIN="$(state_get domain)"
VPN_PORT="$(state_get vpn_port)"
CURRENT_IMAGE="$(state_get current_image)"
[[ -n "${DOMAIN}" && -n "${VPN_PORT}" && -n "${CURRENT_IMAGE}" ]] || die 'Managed state is incomplete.'
validate_domain "${DOMAIN}"
[[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] || die "Certificate is missing for ${DOMAIN}."
openssl x509 -checkend 604800 -noout -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" || \
  die "Certificate for ${DOMAIN} expires in less than seven days."

ensure_openconnect_probe_tools

pull_ui_component() {
  local image="$1" component="$2" actual_version actual_component actual_revision actual_source base_image ocserv_image
  docker pull "${image}" || \
    die "Cannot pull ${image}; make the GHCR package public or pre-authenticate Docker through a reviewed secret flow."
  actual_version="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "${image}")"
  actual_component="$(docker image inspect --format '{{ index .Config.Labels "org.ocserv-vps.component" }}' "${image}")"
  actual_revision="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "${image}")"
  actual_source="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.source" }}' "${image}")"
  [[ "${actual_version}" == "${UI_VERSION}" ]] || die "${component} image version is ${actual_version}; expected ${UI_VERSION}."
  [[ "${actual_component}" == "${component}" ]] || die "Image ${image} is not the ${component} component."
  [[ "${actual_revision}" =~ ^[0-9a-f]{40,64}$ ]] || die "Image ${image} has no valid source revision label."
  [[ "${actual_source}" == 'https://github.com/khorevaa/ocserv-vps' ]] || die "Image ${image} has an unexpected source label."
  if [[ "${component}" == 'ui' ]]; then
    UI_IMAGE_REVISION="${actual_revision}"
    base_image="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.base.name" }}' "${image}")"
    [[ "${base_image}" == 'golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2' ]] || \
      die 'UI image has an unexpected or unpinned Go builder label.'
  else
    CONTROL_IMAGE_REVISION="${actual_revision}"
    ocserv_image="$(docker image inspect --format '{{ index .Config.Labels "org.ocserv-vps.ocserv-image" }}' "${image}")"
    [[ "${ocserv_image}" == "${CURRENT_IMAGE}" ]] || die 'Control image was not built for the active ocserv image tag.'
  fi
}

UI_IMAGE_REVISION=""
CONTROL_IMAGE_REVISION=""
pull_ui_component "${UI_IMAGE}" 'ui'
pull_ui_component "${CONTROL_IMAGE}" 'control'
[[ "${UI_IMAGE_REVISION}" == "${CONTROL_IMAGE_REVISION}" ]] || \
  die 'UI and control images were built from different repository revisions.'

create_stack_backup "before-ui-${UI_VERSION}"
UI_BACKUP="${LAST_BACKUP}"
VPN_LOG_DIR_EXISTED="0"
VPN_JOURNAL_FILE_EXISTED="0"
VPN_JOURNAL_SCRIPT_EXISTED="0"
[[ -d "${OCSERV_LOG_DIR}" && ! -L "${OCSERV_LOG_DIR}" ]] && VPN_LOG_DIR_EXISTED="1"
[[ -f "${OCSERV_VPN_JOURNAL_FILE}" && ! -L "${OCSERV_VPN_JOURNAL_FILE}" ]] && VPN_JOURNAL_FILE_EXISTED="1"
[[ -f "${OCSERV_VPN_JOURNAL_SCRIPT}" && ! -L "${OCSERV_VPN_JOURNAL_SCRIPT}" ]] && VPN_JOURNAL_SCRIPT_EXISTED="1"

UI_AUTH_REQUEST=""
UI_AUTH_RESPONSE=""
UI_AUTH_ACCESS_HEADERS=""
UI_AUTH_COOKIE_HEADER=""
UI_CSRF_HEADER=""
UI_PROBE_REQUEST=""
UI_PROBE_RESPONSE=""
UI_PROBE_PASSWORD_FILE=""
UI_COMMITTED="0"
MUTATION_LOCK_HELD="1"
PROBE_USER_CREATED="0"
PROBE_USERNAME=""
UI_TMPFILES_TEMP=""
HOST_UI_GROUP_CREATED="0"
HOST_UI_USER_CREATED="0"

rollback_ui() {
  local rollback_failed=0 identity_cleanup_safe=1
  warn "UI installation failed; restoring the pre-UI stack from ${UI_BACKUP}."
  set +e
  if [[ "${MUTATION_LOCK_HELD}" != "1" ]]; then
    if acquire_mutation_lock 60; then
      MUTATION_LOCK_HELD="1"
    else
      warn 'Rollback could not reacquire the mutation lock within 60 seconds.'
      warn "ROLLBACK ABORTED to avoid concurrent state corruption; inspect ${UI_BACKUP}."
      set -e
      return 1
    fi
  fi
  if [[ "${PROBE_USER_CREATED}" == "1" ]]; then
    if [[ ! -r "${OCSERV_CONFIG_DIR}/ocpasswd" ]]; then
      warn 'Rollback cannot inspect ocpasswd for the temporary UI probe user.'
      rollback_failed=1
    elif awk -F: -v wanted="${PROBE_USERNAME}" '$1 == wanted {found=1} END {exit(found ? 0 : 1)}' \
         "${OCSERV_CONFIG_DIR}/ocpasswd"; then
      if ! delete_password_user "${CURRENT_IMAGE}" "${PROBE_USERNAME}" >/dev/null 2>&1; then
        warn "Rollback could not delete temporary VPN user ${PROBE_USERNAME}."
        rollback_failed=1
      fi
    fi
  fi
  if ! compose down --volumes >/dev/null 2>&1; then
    warn 'Rollback could not stop the UI Compose project cleanly; reconciliation will continue.'
    rollback_failed=1
    identity_cleanup_safe=0
  fi
  if ! rm -f "${OCSERV_UI_COMPOSE_FILE}" "${OCSERV_UI_ENV_FILE}"; then
    warn 'Rollback could not remove the UI Compose override.'
    rollback_failed=1
    identity_cleanup_safe=0
  fi
  if [[ -f "${UI_BACKUP}/compose.yaml" ]] && \
     ! cp -a "${UI_BACKUP}/compose.yaml" "${OCSERV_COMPOSE_FILE}"; then
    warn 'Rollback could not restore compose.yaml.'
    rollback_failed=1
  fi
  if [[ -f "${UI_BACKUP}/state" ]] && \
     ! cp -a "${UI_BACKUP}/state" "${OCSERV_STATE_FILE}"; then
    warn 'Rollback could not restore managed state.'
    rollback_failed=1
  fi
  if [[ -f "${UI_BACKUP}/config.tar" ]] && \
     ! tar -C "${OCSERV_STACK_ROOT}" -xpf "${UI_BACKUP}/config.tar"; then
    warn 'Rollback could not restore the ocserv configuration.'
    rollback_failed=1
  fi
  if [[ "${VPN_JOURNAL_SCRIPT_EXISTED}" != "1" ]] && ! rm -f "${OCSERV_VPN_JOURNAL_SCRIPT}"; then
    warn 'Rollback could not remove the newly created VPN journal script.'
    rollback_failed=1
  fi
  if [[ "${VPN_JOURNAL_FILE_EXISTED}" != "1" ]] && ! rm -f "${OCSERV_VPN_JOURNAL_FILE}"; then
    warn 'Rollback could not remove the newly created VPN journal file.'
    rollback_failed=1
  fi
  if [[ "${VPN_LOG_DIR_EXISTED}" != "1" && -d "${OCSERV_LOG_DIR}" ]] && ! rmdir "${OCSERV_LOG_DIR}"; then
    warn 'Rollback could not remove the newly created VPN log directory.'
    rollback_failed=1
  fi
  if ! compose up -d --remove-orphans >/dev/null 2>&1; then
    warn 'Rollback could not reactivate the pre-UI Compose stack.'
    rollback_failed=1
  fi
  if ! health_check_stack "${CURRENT_IMAGE}" "${VPN_PORT}" 60; then
    warn 'Rollback VPN health verification failed.'
    rollback_failed=1
  fi
  if ! rm -f "${UI_ACCESS_HANDOFF}"; then
    warn 'Rollback could not remove the initial UI credential handoffs.'
    rollback_failed=1
  fi
  if ! rm -f "${UI_TMPFILES_FILE}"; then
    warn 'Rollback could not remove the UI tmpfiles rule.'
    rollback_failed=1
    identity_cleanup_safe=0
  fi
  systemctl disable --now ocserv-vps-restart.path >/dev/null 2>&1 || true
  if ! rm -f "${OCSERV_UI_RESTART_PATH_UNIT}" "${OCSERV_UI_RESTART_SERVICE_UNIT}" \
      "${OCSERV_UI_ACTION_TMPFILES_FILE}" "${OCSERV_UI_RESTART_TRIGGER}"; then
    warn 'Rollback could not remove the ocserv restart bridge.'
    rollback_failed=1
    identity_cleanup_safe=0
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ -L "${OCSERV_UI_ACTION_DIR}" ]]; then
    warn 'Rollback refuses to follow a symlink at the ocserv action path.'
    rollback_failed=1
    identity_cleanup_safe=0
  elif [[ -d "${OCSERV_UI_ACTION_DIR}" ]] && ! rmdir "${OCSERV_UI_ACTION_DIR}"; then
    warn 'Rollback could not remove the ocserv action directory.'
    rollback_failed=1
    identity_cleanup_safe=0
  fi
  if ! rm -f "${OCSERV_UI_ACCESS_INFO_SCRIPT}"; then
    warn 'Rollback could not remove the UI access-info command.'
    rollback_failed=1
  fi
  if ! rm -f "${UI_WEB_SOCKET}"; then
    warn 'Rollback could not remove the UI web socket.'
    rollback_failed=1
    identity_cleanup_safe=0
  fi
  if [[ -L "${UI_WEB_RUN_DIR}" ]]; then
    warn 'Rollback refuses to follow a symlink at the UI web runtime path.'
    rollback_failed=1
    identity_cleanup_safe=0
  elif [[ -d "${UI_WEB_RUN_DIR}" ]]; then
    if ! rmdir "${UI_WEB_RUN_DIR}"; then
      warn 'Rollback could not remove the UI web runtime directory.'
      rollback_failed=1
      identity_cleanup_safe=0
    fi
  elif [[ -e "${UI_WEB_RUN_DIR}" ]]; then
    warn 'Rollback found an unexpected non-directory at the UI web runtime path.'
    rollback_failed=1
    identity_cleanup_safe=0
  fi
  if ! rm -rf -- "${UI_DATA_DIR}" "${UI_SECRETS_DIR}" "${UI_PUBLIC_DIR}"; then
    warn 'Rollback could not remove all newly created UI directories.'
    rollback_failed=1
    identity_cleanup_safe=0
  fi
  if [[ "${identity_cleanup_safe}" != "1" && \
        ( "${HOST_UI_USER_CREATED}" == "1" || "${HOST_UI_GROUP_CREATED}" == "1" ) ]]; then
    warn 'Rollback retained the reserved UI host identity because container or file cleanup was incomplete.'
    rollback_failed=1
  elif [[ "${HOST_UI_USER_CREATED}" == "1" ]] && \
     getent passwd "${OCSERV_UI_HOST_USER}" >/dev/null 2>&1; then
    if ! ui_host_identity_is_exact; then
      warn 'Rollback refuses to delete the reserved UI host user because its identity changed.'
      rollback_failed=1
    elif ! userdel "${OCSERV_UI_HOST_USER}"; then
      warn 'Rollback could not delete the reserved UI host user.'
      rollback_failed=1
    fi
  fi
  if [[ "${identity_cleanup_safe}" == "1" && "${HOST_UI_GROUP_CREATED}" == "1" ]] && \
     getent group "${OCSERV_UI_HOST_GROUP}" >/dev/null 2>&1; then
    if getent passwd "${OCSERV_UI_HOST_USER}" >/dev/null 2>&1; then
      warn 'Rollback did not delete the reserved UI host group because its user still exists.'
      rollback_failed=1
    elif ! ui_host_group_is_exact; then
      warn 'Rollback refuses to delete the reserved UI host group because its identity or membership changed.'
      rollback_failed=1
    elif getent passwd | awk -F: -v gid="${OCSERV_UI_HOST_GID}" \
         '$4 == gid {found=1} END {exit(found ? 0 : 1)}'; then
      warn 'Rollback refuses to delete the reserved UI host group because another user has it as primary group.'
      rollback_failed=1
    elif ! groupdel "${OCSERV_UI_HOST_GROUP}"; then
      warn 'Rollback could not delete the reserved UI host group.'
      rollback_failed=1
    fi
  fi
  set -e
  if (( rollback_failed != 0 )); then
    warn "ROLLBACK FAILED; keep the independent SSH session open and inspect ${UI_BACKUP}."
    return 1
  fi
  warn 'Rollback completed and the pre-UI VPN listeners are healthy.'
  return 0
}

on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -f \
    "${UI_AUTH_REQUEST:-}" "${UI_AUTH_RESPONSE:-}" \
    "${UI_AUTH_ACCESS_HEADERS:-}" \
    "${UI_AUTH_COOKIE_HEADER:-}" \
    "${UI_CSRF_HEADER:-}" "${UI_PROBE_REQUEST:-}" "${UI_PROBE_RESPONSE:-}" \
    "${UI_PROBE_PASSWORD_FILE:-}" "${UI_TMPFILES_TEMP:-}"
  if [[ "${status}" -ne 0 && "${UI_COMMITTED}" != "1" ]]; then
    if ! rollback_ui; then
      warn "Automatic rollback failed; backup: ${UI_BACKUP}."
    fi
  fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' HUP INT TERM

HOST_UI_GROUP_CREATED="1"
groupadd --system --gid "${OCSERV_UI_HOST_GID}" "${OCSERV_UI_HOST_GROUP}"
HOST_UI_USER_CREATED="1"
useradd --system \
  --uid "${OCSERV_UI_HOST_UID}" \
  --gid "${OCSERV_UI_HOST_GROUP}" \
  --home-dir "${OCSERV_UI_HOST_HOME}" \
  --no-create-home \
  --shell "${OCSERV_UI_HOST_SHELL}" \
  --comment 'Reserved host identity for the isolated ocserv UI container' \
  "${OCSERV_UI_HOST_USER}"
passwd --lock "${OCSERV_UI_HOST_USER}" >/dev/null
ui_host_identity_is_exact || die 'The reserved UI host identity failed its post-creation security checks.'

install -d -m 0755 "${UI_PUBLIC_DIR}"
install -m 0644 "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${UI_PUBLIC_DIR}/fullchain.pem"
install -m 0644 "${OCSERV_STATE_FILE}" "${UI_PUBLIC_DIR}/state"

install -d -m 0700 -o 10001 -g 10001 "${UI_DATA_DIR}"
install -d -m 0750 -o root -g 10001 "${UI_SECRETS_DIR}"
install -d -m 0750 "${UI_LOCK_DIR}"
UI_TMPFILES_TEMP="$(mktemp /etc/tmpfiles.d/.ocserv-vps-ui.conf.XXXXXX)"
printf 'd %s 0700 10001 10001 -\n' "${UI_WEB_RUN_DIR}" > "${UI_TMPFILES_TEMP}"
chmod 0644 "${UI_TMPFILES_TEMP}"
mv -T "${UI_TMPFILES_TEMP}" "${UI_TMPFILES_FILE}"
UI_TMPFILES_TEMP=""
systemd-tmpfiles --create "${UI_TMPFILES_FILE}"
[[ -d "${UI_WEB_RUN_DIR}" && ! -L "${UI_WEB_RUN_DIR}" ]] || \
  die 'systemd-tmpfiles did not create a real UI web runtime directory.'
[[ "$(stat -c '%u:%g %a' "${UI_WEB_RUN_DIR}")" == '10001:10001 700' ]] || \
  die 'The UI web runtime directory has unexpected ownership or permissions.'
install_ocserv_restart_bridge
SESSION_KEY="$(openssl rand -hex 32)"
ACCESS_SECRET="$(openssl rand -hex 32)"
UI_LOCAL_HOST="ocserv-$(openssl rand -hex 16).localhost"
[[ "${UI_LOCAL_HOST}" =~ ^ocserv-[0-9a-f]{32}\.localhost$ ]] || \
  die 'Failed to generate the isolated localhost browser hostname.'
printf '%s\n' "${SESSION_KEY}" > "${UI_SECRETS_DIR}/session-key"
printf '%s\n' "${ACCESS_SECRET}" > "${UI_SECRETS_DIR}/access-secret"
chown root:10001 \
  "${UI_SECRETS_DIR}/session-key" "${UI_SECRETS_DIR}/access-secret"
chmod 0440 \
  "${UI_SECRETS_DIR}/session-key" "${UI_SECRETS_DIR}/access-secret"
cat > "${UI_ACCESS_HANDOFF}" <<EOF
url=http://${UI_LOCAL_HOST}:${UI_PORT}
remote_socket=${UI_WEB_SOCKET}
tunnel_template=ssh -N -L 127.0.0.1:${UI_PORT}:${UI_WEB_SOCKET} root@<vps-host>
access_secret=${ACCESS_SECRET}
expires=operator session is valid for at most 12 hours
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 "${UI_ACCESS_HANDOFF}"

cat > "${OCSERV_UI_ENV_FILE}" <<EOF
OCSERV_UI_IMAGE=${UI_IMAGE}
OCSERV_CONTROL_IMAGE=${CONTROL_IMAGE}
OCSERV_UI_LOCAL_HOST=${UI_LOCAL_HOST}
OCSERV_UI_LOCAL_PORT=${UI_PORT}
OCSERV_UI_SSH_PORT=${SSH_PORT}
OCSERV_UI_VPN_DOMAIN=${DOMAIN}
EOF
chmod 0640 "${OCSERV_UI_ENV_FILE}"
render_ui_access_info_script

cat > "${OCSERV_UI_COMPOSE_FILE}" <<EOF
services:
  ocserv-control:
    image: \${OCSERV_CONTROL_IMAGE}
    container_name: ocserv-vps-control
    network_mode: none
    user: "0:10001"
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      # ocserv creates occtl.sock as ocserv:ocserv mode 0711. The isolated
      # root control process needs only DAC_OVERRIDE to connect and still has
      # no network, Docker socket, or access outside its explicit mounts.
      - DAC_OVERRIDE
    security_opt:
      - no-new-privileges:true
    environment:
      OCSERV_UI_ALLOWED_UID: "10001"
      OCSERV_UI_CERTIFICATE_FILE: /opt/ocserv-vps/ui-public/fullchain.pem
      OCSERV_UI_STATE_FILE: /opt/ocserv-vps/ui-public/state
      OCSERV_UI_JOURNAL_FILE: /opt/ocserv-vps/logs/vpn-events.jsonl
    volumes:
      # A directory mount is required for same-filesystem atomic snapshots of
      # ocpasswd; UI data and UI secrets remain outside this mount.
      - ./config:/opt/ocserv-vps/config:rw
      - ./locks:/opt/ocserv-vps/locks:rw
      - ./ui-public:/opt/ocserv-vps/ui-public:ro
      - ./logs:/opt/ocserv-vps/logs:ro
      - type: bind
        source: ${OCSERV_UI_ACTION_DIR}
        target: ${OCSERV_UI_ACTION_DIR}
        bind:
          create_host_path: false
      - ocserv-control-run:/run/ocserv-control
      - ocserv-ui-run:/run/ocserv-ui
    tmpfs:
      - /tmp:mode=0700
    restart: unless-stopped
    depends_on:
      ocserv:
        condition: service_started

  ocserv-ui:
    image: \${OCSERV_UI_IMAGE}
    container_name: ocserv-vps-ui
    network_mode: none
    user: "10001:10001"
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    environment:
      OCSERV_UI_ALLOWED_ORIGIN: "http://${UI_LOCAL_HOST}:${UI_PORT}"
      OCSERV_UI_IMAGE_NAME: "${UI_IMAGE}"
      OCSERV_UI_VPN_DOMAIN: "${DOMAIN}"
      OCSERV_UI_TRUSTED_PROXY_CIDRS: ""
      OCSERV_UI_JSON: /var/lib/ocserv-ui/state.json
      OCSERV_UI_CONTROL_SOCKET: /run/ocserv-ui/control.sock
      OCSERV_UI_CONTROL_TIMEOUT: "35"
      OCSERV_UI_WEB_SOCKET: ${UI_WEB_SOCKET}
      OCSERV_UI_SESSION_KEY_FILE: /run/secrets/session-key
      OCSERV_UI_ACCESS_SECRET_FILE: /run/secrets/access-secret
    volumes:
      - ./ui-data:/var/lib/ocserv-ui:rw
      - ./ui-secrets:/run/secrets:ro
      - ocserv-ui-run:/run/ocserv-ui
      - type: bind
        source: ${UI_WEB_RUN_DIR}
        target: ${UI_WEB_RUN_DIR}
        bind:
          create_host_path: false
    tmpfs:
      - /tmp:mode=0700,uid=10001,gid=10001
    restart: unless-stopped
    depends_on:
      ocserv-control:
        condition: service_healthy

volumes:
  ocserv-ui-run:
    driver: local
    driver_opts:
      type: tmpfs
      device: tmpfs
      o: size=4m,mode=0710,uid=0,gid=10001
EOF
chmod 0640 "${OCSERV_UI_COMPOSE_FILE}"

if grep -q '^occtl-socket-file[[:space:]]*=' "${OCSERV_CONFIG_DIR}/ocserv.conf"; then
  sed -i 's#^occtl-socket-file[[:space:]]*=.*#occtl-socket-file = /run/ocserv-control/occtl.sock#' "${OCSERV_CONFIG_DIR}/ocserv.conf"
else
  printf '%s\n' 'occtl-socket-file = /run/ocserv-control/occtl.sock' >> "${OCSERV_CONFIG_DIR}/ocserv.conf"
fi
ensure_vpn_journal_config
render_compose_file
test_image_config "${CURRENT_IMAGE}"

compose up -d --remove-orphans
health_check_stack "${CURRENT_IMAGE}" "${VPN_PORT}" 60 || die 'ocserv failed after UI activation.'
health_check_ui_stack 60 || die 'UI control or Unix-socket web health check failed.'
[[ "$(stat -c '%u:%g %a' "${UI_WEB_SOCKET}")" == '10001:10001 600' ]] || \
  die 'The UI web Unix socket is not owner-only (expected 10001:10001 mode 0600).'
[[ "$(docker inspect --format '{{.HostConfig.NetworkMode}}' ocserv-vps-ui)" == 'none' ]] || \
  die 'UI web container unexpectedly has a network namespace.'
UI_PORT_BINDINGS="$(docker inspect --format '{{json .HostConfig.PortBindings}}' ocserv-vps-ui)"
[[ "${UI_PORT_BINDINGS}" == 'null' || "${UI_PORT_BINDINGS}" == '{}' ]] || \
  die 'UI web container unexpectedly publishes a TCP port.'
ui_curl() {
  curl --noproxy '*' --unix-socket "${UI_WEB_SOCKET}" \
    --header "Host: ${UI_LOCAL_HOST}:${UI_PORT}" "$@"
}
ui_curl --fail --silent --show-error "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/health" >/dev/null

UI_AUTH_REQUEST="$(mktemp /run/ocserv-vps-ui-login.XXXXXX)"
UI_AUTH_RESPONSE="$(mktemp /run/ocserv-vps-ui-login-response.XXXXXX)"
UI_AUTH_ACCESS_HEADERS="$(mktemp /run/ocserv-vps-ui-access-headers.XXXXXX)"
UI_AUTH_COOKIE_HEADER="$(mktemp /run/ocserv-vps-ui-cookie-header.XXXXXX)"
UI_CSRF_HEADER="$(mktemp /run/ocserv-vps-ui-csrf.XXXXXX)"
UI_PROBE_REQUEST="$(mktemp /run/ocserv-vps-ui-probe-request.XXXXXX)"
UI_PROBE_RESPONSE="$(mktemp /run/ocserv-vps-ui-probe-response.XXXXXX)"
UI_PROBE_PASSWORD_FILE="$(mktemp /run/ocserv-vps-ui-probe-password.XXXXXX)"
chmod 0600 \
  "${UI_AUTH_REQUEST}" "${UI_AUTH_RESPONSE}" \
  "${UI_AUTH_ACCESS_HEADERS}" \
  "${UI_AUTH_COOKIE_HEADER}" \
  "${UI_CSRF_HEADER}" "${UI_PROBE_REQUEST}" "${UI_PROBE_RESPONSE}" \
  "${UI_PROBE_PASSWORD_FILE}"

write_ui_cookie_header() {
  local session_headers="$1" output_file="$2"
  python3 - "${session_headers}" "${output_file}" <<'PY'
import os
import re
import stat
import sys
from pathlib import Path

SESSION_NAME = "__Host-ocserv_ui_session"
SESSION_PATTERN = re.compile(r"[A-Za-z0-9_-]{43,128}")


def read_cookie(headers_path: str, expected_name: str) -> str:
    raw = Path(headers_path).read_bytes()
    if not raw or len(raw) > 16 * 1024 or b"\x00" in raw:
        raise SystemExit(f"invalid {expected_name} response headers")
    try:
        lines = raw.decode("iso-8859-1").splitlines()
    except UnicodeError:
        raise SystemExit(f"invalid {expected_name} response header encoding") from None

    cookies: list[tuple[str, str, list[str]]] = []
    for line in lines:
        if not line.lower().startswith("set-cookie:"):
            continue
        parts = [part.strip() for part in line.split(":", 1)[1].split(";")]
        if not parts or "=" not in parts[0]:
            raise SystemExit("malformed Set-Cookie response")
        name, value = parts[0].split("=", 1)
        cookies.append((name, value, parts[1:]))
    if len(cookies) != 1 or cookies[0][0] != expected_name:
        raise SystemExit(f"expected exactly one {expected_name} cookie")

    name, value, raw_attributes = cookies[0]
    if SESSION_PATTERN.fullmatch(value) is None:
        raise SystemExit(f"invalid {name} value")
    flags: set[str] = set()
    attributes: dict[str, str] = {}
    for raw_attribute in raw_attributes:
        if not raw_attribute:
            raise SystemExit(f"empty {name} cookie attribute")
        if "=" in raw_attribute:
            key, attribute_value = raw_attribute.split("=", 1)
            key = key.strip().lower()
            if key in attributes or key in flags:
                raise SystemExit(f"duplicate {name} cookie attribute")
            attributes[key] = attribute_value.strip()
        else:
            key = raw_attribute.lower()
            if key in attributes or key in flags:
                raise SystemExit(f"duplicate {name} cookie flag")
            flags.add(key)
    if flags != {"secure", "httponly"}:
        raise SystemExit(f"unsafe {name} cookie flags")
    if set(attributes) != {"max-age", "path", "samesite"}:
        raise SystemExit(f"unexpected {name} cookie attributes")
    if (
        attributes["path"] != "/"
        or attributes["samesite"].lower() != "strict"
        or re.fullmatch(r"[0-9]{1,8}", attributes["max-age"]) is None
        or not 1 <= int(attributes["max-age"]) <= 12 * 60 * 60
    ):
        raise SystemExit(f"unsafe {name} cookie attributes")
    return value


output = Path(sys.argv[2])
output_stat = output.lstat()
if (
    not stat.S_ISREG(output_stat.st_mode)
    or output_stat.st_uid != 0
    or stat.S_IMODE(output_stat.st_mode) != 0o600
    or output_stat.st_nlink != 1
):
    raise SystemExit("unsafe CLI cookie header file")

session_value = read_cookie(sys.argv[1], SESSION_NAME)
flags = os.O_WRONLY | os.O_TRUNC
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(output, flags)
try:
    opened_stat = os.fstat(fd)
    if (
        not stat.S_ISREG(opened_stat.st_mode)
        or opened_stat.st_uid != 0
        or stat.S_IMODE(opened_stat.st_mode) != 0o600
        or opened_stat.st_nlink != 1
        or (opened_stat.st_dev, opened_stat.st_ino)
        != (output_stat.st_dev, output_stat.st_ino)
    ):
        raise SystemExit("CLI cookie header file changed during validation")
    with os.fdopen(fd, "w", encoding="ascii", newline="\n", closefd=False) as stream:
        stream.write(f"Cookie: {SESSION_NAME}={session_value}\n")
finally:
    os.close(fd)
PY
}

UI_LOCKED_STATUS="$(ui_curl \
  --silent --show-error --output /dev/null --write-out '%{http_code}' \
  "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/auth/me")"
[[ "${UI_LOCKED_STATUS}" == "404" ]] || die 'UI access gate did not hide the authenticated API.'
printf '{"secret":"%s"}\n' "${ACCESS_SECRET}" > "${UI_AUTH_REQUEST}"
ui_curl --fail --silent --show-error \
  --request POST \
  --header "Origin: http://${UI_LOCAL_HOST}:${UI_PORT}" \
  --header 'Content-Type: application/json' \
  --dump-header "${UI_AUTH_ACCESS_HEADERS}" \
  --data-binary "@${UI_AUTH_REQUEST}" \
  --output "${UI_AUTH_RESPONSE}" \
  "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/access"
write_ui_cookie_header "${UI_AUTH_ACCESS_HEADERS}" "${UI_AUTH_COOKIE_HEADER}"
python3 - "${UI_AUTH_RESPONSE}" "${UI_CSRF_HEADER}" <<'PY'
import json
import re
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    response = json.load(stream)
if response.get("user") != {"username": "operator", "role": "operator"}:
    raise SystemExit("UI access response did not contain the secret-only operator.")
token = response.get("csrf_token")
if not isinstance(token, str) or re.fullmatch(r"[A-Za-z0-9_-]{20,256}", token) is None:
    raise SystemExit("UI access response did not contain a CSRF token.")
with open(sys.argv[2], "w", encoding="ascii") as stream:
    stream.write(f"X-CSRF-Token: {token}\n")
PY
ui_curl --fail --silent --show-error \
  --header "@${UI_AUTH_COOKIE_HEADER}" \
  "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/overview" >/dev/null

release_mutation_lock
MUTATION_LOCK_HELD="0"
PROBE_USERNAME="ocserv-ui-check-$(openssl rand -hex 4)"
PROBE_USER_CREATED="1"
printf '{"username":"%s"}\n' "${PROBE_USERNAME}" > "${UI_PROBE_REQUEST}"
ui_curl --fail --silent --show-error \
  --request POST \
  --header "Origin: http://${UI_LOCAL_HOST}:${UI_PORT}" \
  --header 'Content-Type: application/json' \
  --header "@${UI_CSRF_HEADER}" \
  --header "@${UI_AUTH_COOKIE_HEADER}" \
  --data-binary "@${UI_PROBE_REQUEST}" \
  --output "${UI_PROBE_RESPONSE}" \
  "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/users"
python3 - "${UI_PROBE_RESPONSE}" "${PROBE_USERNAME}" "${UI_PROBE_PASSWORD_FILE}" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    response = json.load(stream)
if response.get("username") != sys.argv[2]:
    raise SystemExit("UI add-user response did not contain the probe username.")
password = response.get("password")
if not isinstance(password, str) or len(password) < 24 or "\n" in password:
    raise SystemExit("UI add-user response did not contain a safe generated password.")
with open(sys.argv[3], "w", encoding="utf-8") as stream:
    stream.write(password + "\n")
PY
IFS= read -r PROBE_PASSWORD < "${UI_PROBE_PASSWORD_FILE}"
if ! acquire_mutation_lock 60; then
  die 'Could not reacquire the mutation lock after the UI add-user probe.'
fi
MUTATION_LOCK_HELD="1"
verify_openconnect_data_path "${DOMAIN}" "${VPN_PORT}" "${PROBE_USERNAME}" "${PROBE_PASSWORD}"
unset PROBE_PASSWORD

release_mutation_lock
MUTATION_LOCK_HELD="0"
printf '%s\n' '{"terminate_sessions":false}' > "${UI_PROBE_REQUEST}"
ui_curl --fail --silent --show-error \
  --request PUT \
  --header "Origin: http://${UI_LOCAL_HOST}:${UI_PORT}" \
  --header 'Content-Type: application/json' \
  --header "@${UI_CSRF_HEADER}" \
  --header "@${UI_AUTH_COOKIE_HEADER}" \
  --data-binary "@${UI_PROBE_REQUEST}" \
  --output "${UI_PROBE_RESPONSE}" \
  "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/users/${PROBE_USERNAME}/password"
python3 - "${UI_PROBE_RESPONSE}" "${PROBE_USERNAME}" "${UI_PROBE_PASSWORD_FILE}" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    response = json.load(stream)
if response.get("username") != sys.argv[2]:
    raise SystemExit("UI password-rotation response did not contain the probe username.")
password = response.get("password")
if not isinstance(password, str) or len(password) < 24 or "\n" in password:
    raise SystemExit("UI password-rotation response did not contain a safe generated password.")
with open(sys.argv[3], "w", encoding="utf-8") as stream:
    stream.write(password + "\n")
PY
IFS= read -r PROBE_PASSWORD < "${UI_PROBE_PASSWORD_FILE}"
if ! acquire_mutation_lock 60; then
  die 'Could not reacquire the mutation lock after the UI password-rotation probe.'
fi
MUTATION_LOCK_HELD="1"
verify_openconnect_data_path "${DOMAIN}" "${VPN_PORT}" "${PROBE_USERNAME}" "${PROBE_PASSWORD}"
unset PROBE_PASSWORD

delete_password_user "${CURRENT_IMAGE}" "${PROBE_USERNAME}"
PROBE_USER_CREATED="0"
write_state \
  "$(state_get current_version)" "$(state_get current_image)" \
  "$(state_get previous_version)" "$(state_get previous_image)" \
  "$(state_get domain)" "$(state_get vpn_network)" "$(state_get vpn_port)" \
  "$(state_get source_sha256)" "${UI_BACKUP}"
rm -f \
  "${UI_AUTH_REQUEST}" "${UI_AUTH_RESPONSE}" \
  "${UI_AUTH_ACCESS_HEADERS}" \
  "${UI_AUTH_COOKIE_HEADER}" \
  "${UI_CSRF_HEADER}" "${UI_PROBE_REQUEST}" "${UI_PROBE_RESPONSE}" \
  "${UI_PROBE_PASSWORD_FILE}"
UI_AUTH_REQUEST=""
UI_AUTH_RESPONSE=""
UI_AUTH_ACCESS_HEADERS=""
UI_AUTH_COOKIE_HEADER=""
UI_CSRF_HEADER=""
UI_PROBE_REQUEST=""
UI_PROBE_RESPONSE=""
UI_PROBE_PASSWORD_FILE=""
unset SESSION_KEY ACCESS_SECRET
docker kill --signal HUP "${OCSERV_CONTAINER}" >/dev/null 2>&1 || true

UI_COMMITTED="1"
info "ocserv UI ${UI_VERSION} is active behind the secret gate on ${UI_WEB_SOCKET}; no remote TCP listener was created."
info "Forward local port ${UI_PORT} directly to that socket over SSH, then open http://${UI_LOCAL_HOST}:${UI_PORT}."
info "The root-only access secret handoff is ${UI_ACCESS_HANDOFF}; store it securely and delete the file."
info "Backup: ${UI_BACKUP}"
print_ui_access_info_if_installed
