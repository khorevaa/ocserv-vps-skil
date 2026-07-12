#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage: remote-deploy-release.sh --version <version> --source-url <https_url>
  --sha256 <digest> --signature-url <https_url> --signing-key-url <https_url>
  --signing-key-fingerprint <full_fingerprint> --approve-restart [options]
EOF
}

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
APPROVE_RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --source-url) SOURCE_URL="${2:-}"; shift 2 ;;
    --sha256) SHA256="${2:-}"; shift 2 ;;
    --signature-url) SIGNATURE_URL="${2:-}"; shift 2 ;;
    --signing-key-url) SIGNING_KEY_URL="${2:-}"; shift 2 ;;
    --signing-key-fingerprint) SIGNING_KEY_FINGERPRINT="${2:-}"; shift 2 ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --adopt-existing-service) ADOPT_SERVICE="${2:-}"; shift 2 ;;
    --build-jobs) BUILD_JOBS="${2:-}"; shift 2 ;;
    --health-timeout) HEALTH_TIMEOUT="${2:-}"; shift 2 ;;
    --skip-package-install) SKIP_PACKAGE_INSTALL="1"; shift ;;
    --approve-restart) APPROVE_RESTART="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
[[ -n "${VERSION}" && -n "${SOURCE_URL}" && -n "${SHA256}" && -n "${SIGNATURE_URL}" && -n "${SIGNING_KEY_URL}" && -n "${SIGNING_KEY_FINGERPRINT}" ]] || die 'Required release arguments are missing.'
[[ "${APPROVE_RESTART}" == '1' ]] || die '--approve-restart is required.'
validate_version "${VERSION}"
validate_sha256 "${SHA256}"
validate_https_url source-url "${SOURCE_URL}"
validate_https_url signature-url "${SIGNATURE_URL}"
validate_https_url signing-key-url "${SIGNING_KEY_URL}"
validate_config_path "${CONFIG}"
[[ -z "${ADOPT_SERVICE}" ]] || validate_service_name "${ADOPT_SERVICE}"
[[ "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] && (( HEALTH_TIMEOUT >= 5 && HEALTH_TIMEOUT <= 300 )) || die 'Invalid health timeout.'
if [[ -n "${BUILD_JOBS}" ]]; then
  [[ "${BUILD_JOBS}" =~ ^[0-9]+$ ]] && (( BUILD_JOBS >= 1 && BUILD_JOBS <= 32 )) || die 'Invalid build job count.'
fi

require_command systemctl
require_command flock
require_command ss
require_command readlink
require_command install
require_command tar
require_command python3
require_command runuser
require_command useradd

[[ -r /etc/os-release ]] || die '/etc/os-release is unavailable.'
OS_ID="$(. /etc/os-release; printf '%s' "${ID:-}")"
OS_VERSION_ID="$(. /etc/os-release; printf '%s' "${VERSION_ID:-unknown}")"
case "${OS_ID}" in
  debian|ubuntu) ;;
  *) die "Unsupported distribution: ${OS_ID:-unknown}. Expected Debian or Ubuntu." ;;
esac
[[ -r "${CONFIG}" ]] || die "Existing ocserv config is not readable: ${CONFIG}"

install -d -m 0755 "$(dirname "${OCSERV_LOCK}")"
exec 9>"${OCSERV_LOCK}"
flock -n 9 || die 'Another ocserv release operation is running.'

TARGET_RELEASE="${OCSERV_RELEASES_DIR}/${VERSION}"
[[ ! -e "${TARGET_RELEASE}" ]] || die "Target release already exists: ${TARGET_RELEASE}"
if service_exists ocserv.socket && service_active ocserv.socket; then
  die 'Active ocserv.socket is unsupported. Extend the skill before changing this host.'
fi
if service_exists ocserv.service && service_active ocserv.service && [[ "${ADOPT_SERVICE}" != 'ocserv.service' ]]; then
  die 'ocserv.service is active. Rerun with --adopt-existing-service ocserv.service only for a first migration; otherwise extend the scripts before proceeding.'
fi
if [[ -n "${ADOPT_SERVICE}" ]] && ! service_exists "${ADOPT_SERVICE}"; then
  die "Adoption service does not exist: ${ADOPT_SERVICE}"
fi
if [[ -n "${ADOPT_SERVICE}" ]] && service_exists "${OCSERV_SERVICE}"; then
  die 'The managed release service already exists; omit --adopt-existing-service for later upgrades.'
fi

if [[ -z "${BUILD_JOBS}" ]]; then
  BUILD_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
  [[ "${BUILD_JOBS}" =~ ^[0-9]+$ ]] || BUILD_JOBS='1'
  (( BUILD_JOBS <= 4 )) || BUILD_JOBS='4'
  (( BUILD_JOBS >= 1 )) || BUILD_JOBS='1'
fi

install_build_dependencies() {
  require_command apt-get
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=l
  export APT_LISTCHANGES_FRONTEND=none
  info 'Refreshing apt metadata and installing build dependencies only.'
  apt-get update
  local -a base=(
    ca-certificates curl gnupg tar xz-utils build-essential pkg-config
    meson ninja-build python3 autoconf automake libtool gettext
    libgnutls28-dev libev-dev libpam0g-dev liblz4-dev libseccomp-dev
    libreadline-dev libnl-route-3-dev libprotobuf-c-dev protobuf-c-compiler
    libtalloc-dev
  )
  apt-get install -y --no-install-recommends "${base[@]}"

  local -a candidates=(
    autopoint gperf libhttp-parser-dev libllhttp-dev liboath-dev libkrb5-dev
    libradcli-dev libsystemd-dev libmaxminddb-dev libwrap0-dev libpcre2-dev
  )
  local -a available=()
  local package
  for package in "${candidates[@]}"; do
    if apt-cache show "${package}" >/dev/null 2>&1; then
      available+=("${package}")
    fi
  done
  if (( ${#available[@]} > 0 )); then
    apt-get install -y --no-install-recommends "${available[@]}"
  fi
}

if [[ "${SKIP_PACKAGE_INSTALL}" != '1' ]]; then
  install_build_dependencies
fi
for command in curl gpg tar python3 pkg-config; do require_command "${command}"; done

WORKDIR="$(mktemp -d /var/tmp/ocserv-release.XXXXXX)"
TARGET_CREATED='0'
CUTOVER_STARTED='0'
ACTIVATION_COMMITTED='0'
UNIT_TEMP=''

cleanup() {
  if [[ -n "${UNIT_TEMP}" ]]; then
    rm -f "${UNIT_TEMP}"
  fi
  rm -rf "${WORKDIR}"
}

cleanup_failed_target() {
  if [[ "${TARGET_CREATED}" == '1' && "${ACTIVATION_COMMITTED}" != '1' ]]; then
    local active_target
    active_target="$(readlink -f "${OCSERV_CURRENT_LINK}" 2>/dev/null || true)"
    if [[ "${active_target}" != "${TARGET_RELEASE}" ]]; then
      rm -rf "${TARGET_RELEASE}"
    fi
  fi
}

on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${status}" -ne 0 && "${CUTOVER_STARTED}" == '1' && "${ACTIVATION_COMMITTED}" != '1' ]] && declare -F rollback_activation >/dev/null 2>&1; then
    rollback_activation || true
  fi
  cleanup_failed_target
  cleanup
  exit "${status}"
}

on_signal() {
  exit 130
}

trap on_exit EXIT
trap on_signal HUP INT TERM
chmod 0700 "${WORKDIR}"
ARCHIVE="${WORKDIR}/ocserv-source.tar.xz"
SIGNATURE="${WORKDIR}/ocserv-source.sig"
KEY_FILE="${WORKDIR}/ocserv-signing-key.asc"

info "Downloading signed ocserv release ${VERSION}."
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --output "${ARCHIVE}" "${SOURCE_URL}"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --output "${SIGNATURE}" "${SIGNATURE_URL}"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --output "${KEY_FILE}" "${SIGNING_KEY_URL}"

actual_sha="$(sha256sum "${ARCHIVE}" | awk '{print tolower($1)}')"
expected_sha="$(printf '%s' "${SHA256}" | tr '[:upper:]' '[:lower:]')"
[[ "${actual_sha}" == "${expected_sha}" ]] || die "SHA-256 mismatch: expected ${expected_sha}, got ${actual_sha}"
info 'SHA-256 verification passed.'

GNUPGHOME="${WORKDIR}/gnupg"
export GNUPGHOME
install -d -m 0700 "${GNUPGHOME}"
gpg --batch --quiet --import "${KEY_FILE}"
expected_fingerprint="$(normalize_fingerprint "${SIGNING_KEY_FINGERPRINT}")"
[[ "${expected_fingerprint}" =~ ^[0-9A-F]{40,64}$ ]] || die 'Signing fingerprint must be a full hexadecimal fingerprint.'
mapfile -t imported_fingerprints < <(gpg --batch --with-colons --fingerprint | awk -F: '$1 == "fpr" {print toupper($10)}')
printf '%s\n' "${imported_fingerprints[@]}" | grep -Fxq "${expected_fingerprint}" || die 'Imported signing key does not contain the expected fingerprint.'
status_file="${WORKDIR}/gpg-status"
if ! gpg --batch --status-fd 1 --verify "${SIGNATURE}" "${ARCHIVE}" >"${status_file}" 2>"${WORKDIR}/gpg-error"; then
  sed -n '1,80p' "${WORKDIR}/gpg-error" >&2
  die 'Detached signature verification failed.'
fi
if ! awk -v expected="${expected_fingerprint}" '
  $2 == "VALIDSIG" {
    for (i=3; i<=NF; i++) if (toupper($i) == expected) found=1
  }
  END { exit(found ? 0 : 1) }
' "${status_file}"; then
  die 'The valid signature was not bound to the expected signing fingerprint.'
fi
info "Detached signature verification passed for ${expected_fingerprint}."

UNPACK_DIR="${WORKDIR}/unpack"
install -d -m 0750 "${UNPACK_DIR}"
python3 - "${ARCHIVE}" "${UNPACK_DIR}" <<'PYEXTRACT'
import os
import pathlib
import sys
import tarfile

archive, destination = sys.argv[1:]
root = pathlib.Path(destination).resolve()
with tarfile.open(archive, "r:*") as tf:
    for member in tf.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe archive path: {member.name}")
        if member.isdev() or member.isfifo():
            raise SystemExit(f"unsupported special file in archive: {member.name}")
        if member.issym() or member.islnk():
            link = pathlib.PurePosixPath(member.linkname)
            if link.is_absolute():
                raise SystemExit(f"unsafe absolute link: {member.name} -> {member.linkname}")
            combined = path.parent.joinpath(link)
            depth = 0
            for part in combined.parts:
                if part in ("", "."):
                    continue
                if part == "..":
                    depth -= 1
                else:
                    depth += 1
                if depth < 0:
                    raise SystemExit(f"link escapes archive root: {member.name} -> {member.linkname}")
    try:
        tf.extractall(root, filter="data")
    except TypeError:
        tf.extractall(root)
PYEXTRACT

mapfile -t unpack_entries < <(find "${UNPACK_DIR}" -mindepth 1 -maxdepth 1 -print)
if (( ${#unpack_entries[@]} == 1 )) && [[ -d "${unpack_entries[0]}" ]]; then
  SOURCE_DIR="${unpack_entries[0]}"
else
  SOURCE_DIR="${UNPACK_DIR}"
fi

BUILD_USER="_ocservbuild"
if ! id -u "${BUILD_USER}" >/dev/null 2>&1; then
  useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "${BUILD_USER}"
fi
BUILD_HOME="${WORKDIR}/home"
DESTDIR_ROOT="${WORKDIR}/dest"
BUILD_DIR="${WORKDIR}/build"
mkdir -p "${BUILD_HOME}" "${DESTDIR_ROOT}" "${BUILD_DIR}"
chown -R "${BUILD_USER}:${BUILD_USER}" "${WORKDIR}"
BUILD_SYSTEM=""

if [[ -f "${SOURCE_DIR}/meson.build" ]]; then
  require_command meson
  require_command ninja
  BUILD_SYSTEM='meson'
  info "Building ${VERSION} with Meson using ${BUILD_JOBS} job(s)."
  runuser -u "${BUILD_USER}" -- env HOME="${BUILD_HOME}" meson setup \
    "${BUILD_DIR}" "${SOURCE_DIR}" \
    --prefix="${TARGET_RELEASE}" \
    --buildtype=release \
    --wrap-mode=nodownload
  runuser -u "${BUILD_USER}" -- env HOME="${BUILD_HOME}" meson compile -C "${BUILD_DIR}" -j "${BUILD_JOBS}"
  runuser -u "${BUILD_USER}" -- env HOME="${BUILD_HOME}" DESTDIR="${DESTDIR_ROOT}" meson install -C "${BUILD_DIR}" --no-rebuild
elif [[ -x "${SOURCE_DIR}/configure" || -f "${SOURCE_DIR}/configure.ac" ]]; then
  require_command make
  BUILD_SYSTEM='autotools'
  info "Building ${VERSION} with Autotools using ${BUILD_JOBS} job(s)."
  runuser -u "${BUILD_USER}" -- env HOME="${BUILD_HOME}" bash -c '
    set -euo pipefail
    src=$1
    build=$2
    prefix=$3
    jobs=$4
    dest=$5
    if [[ ! -x "$src/configure" ]]; then
      cd "$src"
      autoreconf -fiv
    fi
    cd "$build"
    "$src/configure" --prefix="$prefix"
    make -j "$jobs"
    make DESTDIR="$dest" install
  ' _ "${SOURCE_DIR}" "${BUILD_DIR}" "${TARGET_RELEASE}" "${BUILD_JOBS}" "${DESTDIR_ROOT}"
else
  die 'Signed source tree contains neither meson.build nor a usable Autotools project.'
fi

STAGED_RELEASE="${DESTDIR_ROOT}${TARGET_RELEASE}"
[[ -d "${STAGED_RELEASE}" ]] || die "Build did not create expected staged prefix: ${STAGED_RELEASE}"
STAGED_BINARY="$(find_release_ocserv "${STAGED_RELEASE}" 2>/dev/null || true)"
[[ -n "${STAGED_BINARY}" ]] || die 'Built release does not contain an ocserv executable.'

install -d -m 0755 "${OCSERV_RELEASES_DIR}"
mv "${STAGED_RELEASE}" "${TARGET_RELEASE}"
TARGET_CREATED='1'
chown -R root:root "${TARGET_RELEASE}"
find "${TARGET_RELEASE}" -type d -exec chmod go-w {} +
TARGET_BINARY="$(find_release_ocserv "${TARGET_RELEASE}")"
TARGET_BINARY_RELATIVE="${TARGET_BINARY#${TARGET_RELEASE}/}"
ln -s "${TARGET_BINARY_RELATIVE}" "${TARGET_RELEASE}/ocserv"
info "Built binary: $(binary_version_line "${TARGET_BINARY}")"

test_log="${WORKDIR}/config-test.log"
if ! test_ocserv_config "${TARGET_BINARY}" "${CONFIG}" >"${test_log}" 2>&1; then
  sed -n '1,120p' "${test_log}" >&2
  touch "${TARGET_RELEASE}/.config-test-failed"
  die 'New binary rejected the existing configuration. Live service was not changed.'
fi
info 'New binary accepted the existing configuration.'

cat > "${TARGET_RELEASE}/.ocserv-release-metadata" <<EOF
version=${VERSION}
source_url=${SOURCE_URL}
sha256=${expected_sha}
signing_fingerprint=${expected_fingerprint}
build_system=${BUILD_SYSTEM}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
host_os=${OS_ID:-unknown}-${OS_VERSION_ID:-unknown}
EOF
chmod 0644 "${TARGET_RELEASE}/.ocserv-release-metadata"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${OCSERV_BACKUP_ROOT}/${TIMESTAMP}-${VERSION}"
install -d -m 0700 "${BACKUP_DIR}"
CONFIG_BACKUP_SCOPE="$(config_backup_scope "${CONFIG}")"
tar -C / -cpf "${BACKUP_DIR}/etc-ocserv.tar" "${CONFIG_BACKUP_SCOPE#/}" 2>/dev/null || die 'Could not snapshot the ocserv configuration.'
OLD_TARGET="$(readlink -f "${OCSERV_CURRENT_LINK}" 2>/dev/null || true)"
printf '%s\n' "${OLD_TARGET}" > "${BACKUP_DIR}/previous-current-target"
OLD_VERSION="$(version_from_release_path "${OLD_TARGET}" || true)"
OLD_UNIT_EXISTS='0'
if [[ -f "${OCSERV_UNIT}" ]]; then
  OLD_UNIT_EXISTS='1'
  cp -a "${OCSERV_UNIT}" "${BACKUP_DIR}/ocserv-release.service"
fi
OLD_CUSTOM_ACTIVE="$(bool_service_active "${OCSERV_SERVICE}")"
OLD_CUSTOM_ENABLED="$(bool_service_enabled "${OCSERV_SERVICE}")"
printf 'active=%s\nenabled=%s\n' "${OLD_CUSTOM_ACTIVE}" "${OLD_CUSTOM_ENABLED}" > "${BACKUP_DIR}/managed-service-state"

LEGACY_SERVICE="$(state_get legacy_service || true)"
LEGACY_WAS_ACTIVE="$(state_get legacy_was_active || true)"
LEGACY_WAS_ENABLED="$(state_get legacy_was_enabled || true)"
[[ -n "${LEGACY_WAS_ACTIVE}" ]] || LEGACY_WAS_ACTIVE='0'
[[ -n "${LEGACY_WAS_ENABLED}" ]] || LEGACY_WAS_ENABLED='0'
ADOPT_WAS_ACTIVE='0'
ADOPT_WAS_ENABLED='0'
if [[ -n "${ADOPT_SERVICE}" ]]; then
  ADOPT_WAS_ACTIVE="$(bool_service_active "${ADOPT_SERVICE}")"
  ADOPT_WAS_ENABLED="$(bool_service_enabled "${ADOPT_SERVICE}")"
  LEGACY_SERVICE="${ADOPT_SERVICE}"
  LEGACY_WAS_ACTIVE="${ADOPT_WAS_ACTIVE}"
  LEGACY_WAS_ENABLED="${ADOPT_WAS_ENABLED}"
  systemctl cat "${ADOPT_SERVICE}" > "${BACKUP_DIR}/adopted-service.txt" 2>/dev/null || true
  printf 'service=%s\nactive=%s\nenabled=%s\n' "${ADOPT_SERVICE}" "${ADOPT_WAS_ACTIVE}" "${ADOPT_WAS_ENABLED}" > "${BACKUP_DIR}/adopted-service-state"
fi
if [[ -f "${OCSERV_STATE_FILE}" ]]; then
  cp -a "${OCSERV_STATE_FILE}" "${BACKUP_DIR}/previous-state"
fi

rollback_activation() {
  warn 'Activation failed or was interrupted; restoring the previous service state.'
  set +e
  systemctl stop "${OCSERV_SERVICE}" >/dev/null 2>&1
  if [[ -n "${OLD_TARGET}" ]]; then
    atomic_current_link "${OLD_TARGET}"
  else
    rm -f "${OCSERV_CURRENT_LINK}"
  fi
  if [[ "${OLD_UNIT_EXISTS}" == '1' ]]; then
    cp -a "${BACKUP_DIR}/ocserv-release.service" "${OCSERV_UNIT}"
  else
    rm -f "${OCSERV_UNIT}"
  fi
  systemctl daemon-reload >/dev/null 2>&1

  if [[ "${OLD_UNIT_EXISTS}" == '1' ]]; then
    if [[ "${OLD_CUSTOM_ENABLED}" == '1' ]]; then systemctl enable "${OCSERV_SERVICE}" >/dev/null 2>&1; else systemctl disable "${OCSERV_SERVICE}" >/dev/null 2>&1; fi
    if [[ "${OLD_CUSTOM_ACTIVE}" == '1' ]]; then systemctl start "${OCSERV_SERVICE}" >/dev/null 2>&1; fi
  fi
  if [[ -n "${ADOPT_SERVICE}" ]]; then
    if [[ "${ADOPT_WAS_ENABLED}" == '1' ]]; then systemctl enable "${ADOPT_SERVICE}" >/dev/null 2>&1; else systemctl disable "${ADOPT_SERVICE}" >/dev/null 2>&1; fi
    if [[ "${ADOPT_WAS_ACTIVE}" == '1' ]]; then systemctl start "${ADOPT_SERVICE}" >/dev/null 2>&1; fi
  fi
  CUTOVER_STARTED='0'
  set -e
}

CUTOVER_STARTED='1'
UNIT_TEMP="$(mktemp /etc/systemd/system/.ocserv-release.service.XXXXXX)"
cat > "${UNIT_TEMP}" <<EOF
[Unit]
Description=OpenConnect SSL VPN server (versioned ocserv release)
Documentation=https://ocserv.gitlab.io/www/
Wants=network-online.target
After=network-online.target dbus.service

[Service]
Type=simple
WorkingDirectory=/
PrivateTmp=true
RuntimeDirectory=ocserv-release
RuntimeDirectoryMode=0750
ExecStart=${OCSERV_CURRENT_LINK}/ocserv --foreground --pid-file /run/ocserv-release/ocserv.pid --config ${CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "${UNIT_TEMP}"
mv -f "${UNIT_TEMP}" "${OCSERV_UNIT}"
UNIT_TEMP=''
systemctl daemon-reload

info 'Cutover begins now; active VPN sessions will disconnect.'
activation_failed='0'
set +e
if [[ "${OLD_CUSTOM_ACTIVE}" == '1' ]]; then
  systemctl stop "${OCSERV_SERVICE}"
  [[ $? -eq 0 ]] || activation_failed='1'
fi
if [[ -n "${ADOPT_SERVICE}" ]]; then
  systemctl stop "${ADOPT_SERVICE}"
  [[ $? -eq 0 ]] || activation_failed='1'
  if [[ "${ADOPT_WAS_ENABLED}" == '1' ]]; then
    systemctl disable "${ADOPT_SERVICE}"
    [[ $? -eq 0 ]] || activation_failed='1'
  fi
fi
if [[ "${activation_failed}" == '0' ]]; then
  atomic_current_link "${TARGET_RELEASE}"
  [[ $? -eq 0 ]] || activation_failed='1'
fi
if [[ "${activation_failed}" == '0' ]]; then
  systemctl enable "${OCSERV_SERVICE}"
  [[ $? -eq 0 ]] || activation_failed='1'
fi
if [[ "${activation_failed}" == '0' ]]; then
  systemctl restart "${OCSERV_SERVICE}"
  [[ $? -eq 0 ]] || activation_failed='1'
fi
set -e

if [[ "${activation_failed}" != '0' ]] || ! health_check_release "${OCSERV_SERVICE}" "${TARGET_BINARY}" "${CONFIG}" "${HEALTH_TIMEOUT}"; then
  rollback_activation
  die "Release ${VERSION} failed activation and the previous service state was restored. Backup: ${BACKUP_DIR}"
fi

write_state "${VERSION}" "${OLD_VERSION}" "${LEGACY_SERVICE}" "${LEGACY_WAS_ACTIVE}" "${LEGACY_WAS_ENABLED}" "${BACKUP_DIR}"
ACTIVATION_COMMITTED='1'
CUTOVER_STARTED='0'
info "Release ${VERSION} is active."
info "Current link: ${OCSERV_CURRENT_LINK} -> ${TARGET_RELEASE}"
info "Backup: ${BACKUP_DIR}"
info "Previous retained version: ${OLD_VERSION:-none}"
