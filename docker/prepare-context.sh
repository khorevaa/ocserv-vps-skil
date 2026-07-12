#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Usage: prepare-context.sh <source-url> <sha256> <signature-url> <signing-key-url> <fingerprint> <output-dir>

Download, authenticate, safely extract, and copy an ocserv source release into <output-dir>/source.
EOF
}

[[ $# -eq 6 ]] || { usage >&2; exit 2; }
SOURCE_URL="$1"
SHA256="$2"
SIGNATURE_URL="$3"
SIGNING_KEY_URL="$4"
FINGERPRINT="$5"
OUTPUT_DIR="$6"

[[ "${SOURCE_URL}" == https://* && "${SIGNATURE_URL}" == https://* && "${SIGNING_KEY_URL}" == https://* ]] || {
  printf '%s\n' 'All artifact URLs must use HTTPS.' >&2
  exit 2
}
[[ "${SHA256}" =~ ^[0-9A-Fa-f]{64}$ ]] || { printf '%s\n' 'Invalid SHA-256.' >&2; exit 2; }
FINGERPRINT="$(printf '%s' "${FINGERPRINT}" | tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]')"
[[ "${FINGERPRINT}" =~ ^[0-9A-F]{40,64}$ ]] || { printf '%s\n' 'Invalid full fingerprint.' >&2; exit 2; }

for command in curl gpg sha256sum python3 tar; do
  command -v "${command}" >/dev/null 2>&1 || { printf 'Missing command: %s\n' "${command}" >&2; exit 2; }
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT HUP INT TERM
ARCHIVE="${WORKDIR}/source.tar"
SIGNATURE="${WORKDIR}/source.sig"
KEY_FILE="${WORKDIR}/signing-key.asc"
GNUPGHOME="${WORKDIR}/gnupg"
UNPACK_DIR="${WORKDIR}/unpack"
export GNUPGHOME

curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --output "${ARCHIVE}" "${SOURCE_URL}"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --output "${SIGNATURE}" "${SIGNATURE_URL}"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --output "${KEY_FILE}" "${SIGNING_KEY_URL}"

ACTUAL_SHA="$(sha256sum "${ARCHIVE}" | awk '{print tolower($1)}')"
EXPECTED_SHA="$(printf '%s' "${SHA256}" | tr '[:upper:]' '[:lower:]')"
[[ "${ACTUAL_SHA}" == "${EXPECTED_SHA}" ]] || {
  printf 'SHA-256 mismatch: expected %s, got %s\n' "${EXPECTED_SHA}" "${ACTUAL_SHA}" >&2
  exit 1
}

install -d -m 0700 "${GNUPGHOME}"
gpg --batch --quiet --import "${KEY_FILE}"
gpg --batch --with-colons --fingerprint | awk -F: '$1 == "fpr" {print toupper($10)}' | \
  grep -Fxq "${FINGERPRINT}" || { printf '%s\n' 'Expected fingerprint was not imported.' >&2; exit 1; }
STATUS_FILE="${WORKDIR}/gpg-status"
gpg --batch --status-fd 1 --verify "${SIGNATURE}" "${ARCHIVE}" > "${STATUS_FILE}" 2> "${WORKDIR}/gpg-error" || {
  sed -n '1,80p' "${WORKDIR}/gpg-error" >&2
  exit 1
}
awk -v expected="${FINGERPRINT}" '$2 == "VALIDSIG" {for (i=3; i<=NF; i++) if (toupper($i) == expected) found=1} END {exit(found ? 0 : 1)}' \
  "${STATUS_FILE}" || { printf '%s\n' 'Valid signature was not bound to the expected fingerprint.' >&2; exit 1; }

install -d -m 0750 "${UNPACK_DIR}"
python3 - "${ARCHIVE}" "${UNPACK_DIR}" <<'PY'
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
            raise SystemExit(f"unsupported special file: {member.name}")
        if member.issym() or member.islnk():
            link = pathlib.PurePosixPath(member.linkname)
            if link.is_absolute():
                raise SystemExit(f"unsafe absolute link: {member.name}")
            depth = 0
            for part in path.parent.joinpath(link).parts:
                if part in ("", "."):
                    continue
                depth += -1 if part == ".." else 1
                if depth < 0:
                    raise SystemExit(f"link escapes archive root: {member.name}")
    try:
        tf.extractall(root, filter="data")
    except TypeError:
        tf.extractall(root)
PY

mapfile -t TOP_ENTRIES < <(find "${UNPACK_DIR}" -mindepth 1 -maxdepth 1 -print)
if (( ${#TOP_ENTRIES[@]} == 1 )) && [[ -d "${TOP_ENTRIES[0]}" ]]; then
  SOURCE_DIR="${TOP_ENTRIES[0]}"
else
  SOURCE_DIR="${UNPACK_DIR}"
fi

rm -rf "${OUTPUT_DIR}/source"
install -d -m 0750 "${OUTPUT_DIR}/source"
cp -a "${SOURCE_DIR}/." "${OUTPUT_DIR}/source/"
printf 'Prepared verified source %s in %s/source\n' "${EXPECTED_SHA}" "${OUTPUT_DIR}"
