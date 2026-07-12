#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ssh-with-password.sh [--ssh-password <pass>] <ssh arguments...>

Run ssh with optional plain-text password support through SSH_ASKPASS.
EOF
}

SSH_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-password)
      SSH_PASSWORD="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

if [[ -z "${SSH_PASSWORD}" ]]; then
  exec ssh "$@"
fi

ASKPASS_SCRIPT="$(mktemp)"
cleanup() {
  rm -f "${ASKPASS_SCRIPT}"
}
trap cleanup EXIT HUP INT TERM

cat > "${ASKPASS_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${OCSERV_SSH_PASSWORD?}"
EOF
chmod 700 "${ASKPASS_SCRIPT}"

export OCSERV_SSH_PASSWORD="${SSH_PASSWORD}"
export SSH_ASKPASS="${ASKPASS_SCRIPT}"
export SSH_ASKPASS_REQUIRE="force"
export DISPLAY="${DISPLAY:-ocserv-codex-askpass}"

ssh \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password,keyboard-interactive \
  -o NumberOfPasswordPrompts=1 \
  "$@"
