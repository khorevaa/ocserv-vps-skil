#!/usr/bin/env bash
set -euo pipefail

args=(
  --foreground
  --pid-file /run/ocserv/ocserv.pid
  --config /etc/ocserv/ocserv.conf
)

if /usr/local/sbin/ocserv --help 2>&1 | grep -q -- '--log-stderr'; then
  args+=(--log-stderr)
fi

exec /usr/local/sbin/ocserv "${args[@]}"
