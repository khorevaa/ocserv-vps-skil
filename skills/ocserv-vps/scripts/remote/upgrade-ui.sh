#!/usr/bin/env bash

UI_VERSION="" UI_IMAGE="" CONTROL_IMAGE="" APPROVE_RESTART="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ui-version) UI_VERSION="${2:-}"; shift 2 ;;
    --ui-image) UI_IMAGE="${2:-}"; shift 2 ;;
    --control-image) CONTROL_IMAGE="${2:-}"; shift 2 ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done
require_root
[[ -n "${UI_VERSION}" && -n "${UI_IMAGE}" && -n "${CONTROL_IMAGE}" ]] || die 'UI version and images are required.'
[[ "${APPROVE_RESTART}" == 1 ]] || die '--approve-restart is required.'
validate_version "${UI_VERSION}"; validate_registry_image "${UI_IMAGE}"; validate_registry_image "${CONTROL_IMAGE}"
[[ "${UI_IMAGE}" == "ghcr.io/khorevaa/ocserv-vps-ui-web:${UI_VERSION}" ]] || die 'Unexpected UI image.'
[[ "${CONTROL_IMAGE}" == "ghcr.io/khorevaa/ocserv-vps-ui-control:${UI_VERSION}" ]] || die 'Unexpected control image.'
for path in "${OCSERV_STATE_FILE}" "${OCSERV_ENV_FILE}" "${OCSERV_COMPOSE_FILE}" "${OCSERV_UI_ENV_FILE}" "${OCSERV_UI_COMPOSE_FILE}"; do
  [[ -f "${path}" && ! -L "${path}" ]] || die "Managed file is missing or unsafe: ${path}"
done
for command in awk curl docker flock openssl stat systemctl systemd-tmpfiles; do require_command "${command}"; done
acquire_stack_locks
CURRENT_IMAGE="$(state_get current_image)"; VPN_PORT="$(state_get vpn_port)"; DOMAIN="$(state_get domain)"
[[ -n "${CURRENT_IMAGE}" && -n "${VPN_PORT}" && -n "${DOMAIN}" ]] || die 'Managed VPN state is incomplete.'
validate_domain "${DOMAIN}"

validate_component() {
  local image="$1" component="$2" version revision source compatibility
  docker pull "${image}"
  version="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "${image}")"
  revision="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "${image}")"
  source="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.source" }}' "${image}")"
  [[ "${version}" == "${UI_VERSION}" && "${revision}" =~ ^[0-9a-f]{40,64}$ ]] || die "Invalid ${component} image metadata."
  [[ "${source}" == 'https://github.com/khorevaa/ocserv-vps' ]] || die "Invalid ${component} source label."
  [[ "$(docker image inspect --format '{{ index .Config.Labels "org.ocserv-vps.component" }}' "${image}")" == "${component}" ]] || die "Invalid ${component} label."
  if [[ "${component}" == control ]]; then
    compatibility="$(docker image inspect --format '{{ index .Config.Labels "org.ocserv-vps.ocserv-image" }}' "${image}")"
    [[ "${compatibility}" == "${CURRENT_IMAGE}" ]] || die 'Control image is incompatible with active ocserv.'
  fi
  COMPONENT_REVISION="${revision}"
}
validate_component "${UI_IMAGE}" ui; UI_REVISION="${COMPONENT_REVISION}"
validate_component "${CONTROL_IMAGE}" control; [[ "${COMPONENT_REVISION}" == "${UI_REVISION}" ]] || die 'UI/control revisions differ.'

UI_LOCAL_HOST="$(awk -F= '$1=="OCSERV_UI_LOCAL_HOST"{print substr($0,index($0,"=")+1)}' "${OCSERV_UI_ENV_FILE}")"
UI_PORT="$(awk -F= '$1=="OCSERV_UI_LOCAL_PORT"{print substr($0,index($0,"=")+1)}' "${OCSERV_UI_ENV_FILE}")"
SSH_PORT="$(awk -F= '$1=="OCSERV_UI_SSH_PORT"{print substr($0,index($0,"=")+1)}' "${OCSERV_UI_ENV_FILE}")"
[[ "${UI_LOCAL_HOST}" =~ ^ocserv-[0-9a-f]{32}\.localhost$ ]] || die 'Unsafe UI hostname.'
validate_port 'UI port' "${UI_PORT}"; validate_port 'SSH port' "${SSH_PORT}"
create_stack_backup "before-ui-upgrade-${UI_VERSION}"; BACKUP_DIR="${LAST_BACKUP}"; COMMITTED="0"
restore_previous() {
  warn "Restoring previous UI stack from ${BACKUP_DIR}."
  cp -a "${BACKUP_DIR}/compose.yaml" "${OCSERV_COMPOSE_FILE}"
  cp -a "${BACKUP_DIR}/compose.ui.yaml" "${OCSERV_UI_COMPOSE_FILE}"
  cp -a "${BACKUP_DIR}/ui.env" "${OCSERV_UI_ENV_FILE}"
  tar -C "${OCSERV_STACK_ROOT}" -xpf "${BACKUP_DIR}/config.tar"
  compose up -d --remove-orphans >/dev/null
  health_check_stack "${CURRENT_IMAGE}" "${VPN_PORT}" 60
  health_check_ui_stack 60
}
on_exit(){ local status=$?; trap - EXIT HUP INT TERM; if [[ "${status}" -ne 0 && "${COMMITTED}" != 1 ]]; then restore_previous || warn 'Automatic UI rollback failed.'; fi; exit "${status}"; }
trap on_exit EXIT; trap 'exit 130' HUP INT TERM

ensure_vpn_journal_config
render_compose_file
cat > "${OCSERV_UI_ENV_FILE}" <<EOF
OCSERV_UI_IMAGE=${UI_IMAGE}
OCSERV_CONTROL_IMAGE=${CONTROL_IMAGE}
OCSERV_UI_LOCAL_HOST=${UI_LOCAL_HOST}
OCSERV_UI_LOCAL_PORT=${UI_PORT}
OCSERV_UI_SSH_PORT=${SSH_PORT}
OCSERV_UI_VPN_DOMAIN=${DOMAIN}
EOF
chmod 0640 "${OCSERV_UI_ENV_FILE}"
cat > "${OCSERV_UI_COMPOSE_FILE}" <<EOF
services:
  ocserv-control:
    image: \${OCSERV_CONTROL_IMAGE}
    container_name: ocserv-vps-control
    network_mode: none
    user: "0:10001"
    read_only: true
    cap_drop: [ALL]
    cap_add: [DAC_OVERRIDE]
    security_opt: ["no-new-privileges:true"]
    environment:
      OCSERV_UI_ALLOWED_UID: "10001"
      OCSERV_UI_CERTIFICATE_FILE: /opt/ocserv-vps/ui-public/fullchain.pem
      OCSERV_UI_STATE_FILE: /opt/ocserv-vps/ui-public/state
      OCSERV_UI_JOURNAL_FILE: /opt/ocserv-vps/logs/vpn-events.jsonl
    volumes:
      - ./config:/opt/ocserv-vps/config:rw
      - ./locks:/opt/ocserv-vps/locks:rw
      - ./ui-public:/opt/ocserv-vps/ui-public:ro
      - ./logs:/opt/ocserv-vps/logs:ro
      - type: bind
        source: ${OCSERV_UI_ACTION_DIR}
        target: ${OCSERV_UI_ACTION_DIR}
        bind: {create_host_path: false}
      - ocserv-control-run:/run/ocserv-control
      - ocserv-ui-run:/run/ocserv-ui
    tmpfs: ["/tmp:mode=0700"]
    restart: unless-stopped
    depends_on:
      ocserv: {condition: service_started}
  ocserv-ui:
    image: \${OCSERV_UI_IMAGE}
    container_name: ocserv-vps-ui
    network_mode: none
    user: "10001:10001"
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    environment:
      OCSERV_UI_ALLOWED_ORIGIN: "http://${UI_LOCAL_HOST}:${UI_PORT}"
      OCSERV_UI_IMAGE_NAME: "${UI_IMAGE}"
      OCSERV_UI_VPN_DOMAIN: "${DOMAIN}"
      OCSERV_UI_TRUSTED_PROXY_CIDRS: ""
      OCSERV_UI_JSON: /var/lib/ocserv-ui/state.json
      OCSERV_UI_CONTROL_SOCKET: /run/ocserv-ui/control.sock
      OCSERV_UI_CONTROL_TIMEOUT: "35"
      OCSERV_UI_WEB_SOCKET: ${OCSERV_UI_WEB_SOCKET}
      OCSERV_UI_SESSION_KEY_FILE: /run/secrets/session-key
      OCSERV_UI_ACCESS_SECRET_FILE: /run/secrets/access-secret
    volumes:
      - ./ui-data:/var/lib/ocserv-ui:rw
      - ./ui-secrets:/run/secrets:ro
      - ocserv-ui-run:/run/ocserv-ui
      - type: bind
        source: ${OCSERV_UI_WEB_RUN_DIR}
        target: ${OCSERV_UI_WEB_RUN_DIR}
        bind: {create_host_path: false}
    tmpfs: ["/tmp:mode=0700,uid=10001,gid=10001"]
    restart: unless-stopped
    depends_on:
      ocserv-control: {condition: service_healthy}
volumes:
  ocserv-ui-run:
    driver: local
    driver_opts: {type: tmpfs, device: tmpfs, o: "size=4m,mode=0710,uid=0,gid=10001"}
EOF
chmod 0640 "${OCSERV_UI_COMPOSE_FILE}"
install_ocserv_restart_bridge
render_ui_access_info_script
compose up -d --remove-orphans
health_check_stack "${CURRENT_IMAGE}" "${VPN_PORT}" 60 || die 'VPN health failed after UI upgrade.'
health_check_ui_stack 60 || die 'UI health failed after upgrade.'
[[ "$(docker inspect --format '{{.Config.Image}}' ocserv-vps-ui)" == "${UI_IMAGE}" ]] || die 'Wrong UI image active.'
[[ "$(docker inspect --format '{{.Config.Image}}' ocserv-vps-control)" == "${CONTROL_IMAGE}" ]] || die 'Wrong control image active.'
curl --noproxy '*' --unix-socket "${OCSERV_UI_WEB_SOCKET}" --header "Host: ${UI_LOCAL_HOST}:${UI_PORT}" --fail --silent --show-error "http://${UI_LOCAL_HOST}:${UI_PORT}/api/v1/health" >/dev/null
COMMITTED="1"
info "UI ${UI_VERSION} is active; access secret, random URL, and JSON state were preserved."
info "Backup: ${BACKUP_DIR}"
print_ui_access_info_if_installed
