---
name: ocserv-vps
description: Deploy and operate the khorevaa/ocserv-vps distribution on an amd64 Debian or Ubuntu VPS over SSH. Use when Codex must inspect a VPS, install the release manager, deploy ocserv, verify health, manage VPN users, update or roll back the server, troubleshoot the managed stack, uninstall it, or optionally install, update, and access the private management UI. Delegate all build, container, firewall, certificate, and UI implementation to the official ocserv-vps manager.
---

# ocserv VPS

Use the released manager from [khorevaa/ocserv-vps](https://github.com/khorevaa/ocserv-vps) as the only deployment implementation. Orchestrate it over SSH; do not copy its runtime scripts into this skill and do not rebuild ocserv or UI images here.

## Safety rules

- Start with read-only inspection. Mutate the VPS only when the user asked to deploy, update, roll back, manage users, install the UI, or uninstall.
- Keep the current SSH session open and confirm the real SSH port before installation. Installing ocserv replaces host firewall rules and can interrupt SSH and VPN sessions.
- Use an explicit released manager tag. Resolve the latest stable GitHub release when the user did not choose one. Do not use the mutable `develop` branch unless the user explicitly requests development code.
- Run stack mutations through `sudo ocserv-vps ...`. Do not invoke files under `/usr/local/lib/ocserv-vps/scripts` directly or repair Docker, iptables, certificates, Compose files, or `/opt/ocserv-vps` state by hand.
- Default to VPN-only deployment. Set `OCSERV_INSTALL_UI=1` only when the user requests the UI; otherwise set it explicitly to `0`.
- Never publish a UI port. Keep the UI behind its Unix socket and an SSH tunnel.
- Never repeat generated VPN passwords or UI access secrets in chat, summaries, logs, or command arguments. Tell the user how to retrieve them in their own SSH session.
- Require an explicit request before `uninstall`; require a separate explicit request before destructive `--purge-data`.

## Collect inputs

Obtain or discover:

- SSH target, user, port, and authentication method
- VPN domain and ACME email
- initial VPN username
- whether to install the UI
- optional VPN port, network, DNS servers, public interface, nginx ACME mode, server image version, UI version, and manager release tag

Use manager defaults for optional values the user did not specify. Never invent a domain, email, SSH port, or UI choice.

## Deployment workflow

### 1. Inspect the VPS

Use read-only SSH commands to verify:

- Debian or Ubuntu on `amd64`/`x86_64`
- root access or passwordless/non-interactive `sudo`
- a character device at `/dev/net/tun`
- working DNS, outbound HTTPS, `curl`, `ip`, and `ss`
- the public interface and public IPv4
- listeners on the intended SSH, VPN TCP/UDP, and ACME port 80
- whether `ocserv-vps`, Docker, or a stack under `/opt/ocserv-vps` already exists

Resolve the domain's A record and require it to point to the VPS. Confirm the provider firewall allows the actual SSH port, TCP 80 for ACME when required, and the selected VPN port over both TCP and UDP.

Treat unsupported OS/architecture, missing TUN, mismatched DNS, unexplained occupied VPN ports, inaccessible ACME port, and ambiguous existing state as blockers.

### 2. Install a pinned manager release

Validate the selected tag against the repository's published releases, then download `install.sh` from that same tag on the VPS:

```bash
MANAGER_TAG=vX.Y.Z
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --output /tmp/ocserv-vps-install.sh \
  "https://raw.githubusercontent.com/khorevaa/ocserv-vps/$MANAGER_TAG/install.sh"
sudo env OCSERV_VPS_INSTALL_ONLY=1 \
  bash /tmp/ocserv-vps-install.sh "$MANAGER_TAG"
rm -f /tmp/ocserv-vps-install.sh
sudo ocserv-vps help
```

If `curl` is absent, download the tagged installer on the controller and upload it over SCP. Do not fall back to an unpinned branch.

For an existing managed server, inspect `sudo ocserv-vps status` and `sudo ocserv-vps settings` before deciding whether only `update-manager`, `update`, or another operation is needed. Do not run `install` over an existing managed stack.

### 3. Deploy ocserv

For unattended deployment, pass required approvals and set the UI decision explicitly:

```bash
sudo env \
  OCSERV_VPS_NONINTERACTIVE=1 \
  OCSERV_DOMAIN=vpn.example.com \
  OCSERV_ACME_EMAIL=admin@example.com \
  OCSERV_VPN_USERNAME=vpnuser \
  OCSERV_SSH_PORT=22 \
  OCSERV_INSTALL_UI=0 \
  OCSERV_APPROVE_FIREWALL=1 \
  OCSERV_APPROVE_RESTART=1 \
  ocserv-vps install
```

Set `OCSERV_INSTALL_UI=1` only for a requested combined VPN+UI deployment. Add these variables only when the user chose non-default values:

- `OCSERV_VERSION`
- `OCSERV_UI_VERSION` and `OCSERV_UI_PORT`
- `OCSERV_VPN_NETWORK` and `OCSERV_VPN_PORT`
- `OCSERV_DNS_PRIMARY` and `OCSERV_DNS_SECONDARY`
- `OCSERV_PUBLIC_INTERFACE`
- `OCSERV_PREPARE_NGINX=1`

Do not hide a non-zero exit code. The manager performs transactional configuration, image validation, certificate setup, firewall/NAT setup, service health checks, and a real OpenConnect data-path probe.

### 4. Verify

Run:

```bash
sudo ocserv-vps status
```

Require a healthy managed container, valid configuration and certificate state, expected TCP/UDP listeners, active network service, and a successful OpenConnect check. When the UI was requested, also run:

```bash
sudo ocserv-vps ui-status
```

Keep the independent SSH session open until these checks pass. Ask the user to test an external OpenConnect/AnyConnect-compatible client before considering a fresh deployment fully handed off.

### 5. Hand off secrets safely

Do not run secret-printing commands through a recorded tool unless the user explicitly accepts that exposure. Tell the user to retrieve credentials directly in their private SSH terminal:

```bash
sudo ocserv-vps vpn-access
```

The initial root-only credential backup is `/root/ocserv-vps-initial-credentials`. New user credentials are written to `/root/ocserv-vps-user-<username>`. Advise storing them in a password manager and deleting each handoff file afterward.

Report the domain, username, installed versions, health result, UI choice, and relevant non-secret commands. Never include passwords or access secrets.

## Optional UI

Install the UI later only when requested:

```bash
sudo env \
  OCSERV_VPS_NONINTERACTIVE=1 \
  OCSERV_SSH_PORT=22 \
  OCSERV_APPROVE_RESTART=1 \
  ocserv-vps install-ui
```

Set `OCSERV_UI_VERSION` or `OCSERV_UI_PORT` only when the user selected them. Verify with `sudo ocserv-vps ui-status`.

Have the user run `sudo ocserv-vps ui-access` in a private SSH terminal. It prints the secret, the exact random `http://ocserv-<32hex>.localhost:<port>/` URL, and the SSH tunnel command for `/run/ocserv-ui-web/web.sock`. Use that exact hostname; do not substitute literal `localhost`. Bind the local forward only to `127.0.0.1`.

Do not create a public UI listener, nginx proxy, Docker port binding, or firewall rule.

## Operations

Use the manager command that matches the request:

| Request | Command |
| --- | --- |
| Inspect VPN | `sudo ocserv-vps status` |
| Inspect UI | `sudo ocserv-vps ui-status` |
| Show non-secret settings | `sudo ocserv-vps settings` |
| Add or rotate a user | `sudo ocserv-vps add-user <username>` |
| Update server image | `sudo env OCSERV_VPS_NONINTERACTIVE=1 OCSERV_VERSION=<version> OCSERV_APPROVE_RESTART=1 ocserv-vps update` |
| Roll back server image | `sudo env OCSERV_VPS_NONINTERACTIVE=1 OCSERV_ROLLBACK_VERSION=previous OCSERV_APPROVE_RESTART=1 ocserv-vps rollback` |
| Update UI | `sudo env OCSERV_VPS_NONINTERACTIVE=1 OCSERV_UI_VERSION=<version> OCSERV_APPROVE_RESTART=1 ocserv-vps update-ui` |
| Rotate UI access | `sudo env OCSERV_VPS_NONINTERACTIVE=1 OCSERV_APPROVE_RESTART=1 ocserv-vps rotate-ui-access` |
| Start, stop, restart | `sudo ocserv-vps start|stop|restart` |
| Follow logs | `sudo ocserv-vps logs` |
| Update manager | Repeat the pinned manager installation workflow with the new released tag |
| Uninstall, preserve data | `sudo env OCSERV_VPS_NONINTERACTIVE=1 OCSERV_APPROVE_UNINSTALL=1 ocserv-vps uninstall` |
| Uninstall and purge data | `sudo env OCSERV_VPS_NONINTERACTIVE=1 OCSERV_APPROVE_UNINSTALL=1 ocserv-vps uninstall --purge-data` |

For updates and rollback, keep the SSH session open, state that active VPN sessions may disconnect, and verify `status` afterward. The manager restores the previous release when its activation checks fail.

## Failure handling

Collect `ocserv-vps status`, `ocserv-vps ui-status` when applicable, `ocserv-vps settings`, and a bounded log excerpt. Report the failed stage and preserve the original exit code.

Prefer retrying a released manager operation or rolling back through the manager. If the manager itself is missing or damaged, reinstall the same released tag with `OCSERV_VPS_INSTALL_ONLY=1`. Stop before manual firewall, certificate, Docker, or state repairs and explain why manager-level recovery is insufficient.
