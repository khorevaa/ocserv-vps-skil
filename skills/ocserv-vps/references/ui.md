# Dockerized ocserv UI

## Topology

Keep ocserv on its existing TCP and UDP VPN port. Give the UI no VPS TCP
listener at all. OpenSSH maps a controller-local TCP port directly to the
remote Unix socket:

```text
browser http://ocserv-<32hex>.localhost:8765
  `-> OpenSSH local TCP forward
      `-> VPS /run/ocserv-ui-web/web.sock -> ocserv-ui
                                               |-- secret-to-session exchange
                                               `-> /run/ocserv-ui/control.sock -> ocserv-control
                                                                                  |-- ocpasswd
                                                                                  |-- occtl socket
                                                                                  `-- read-only VPN journal
```

Do not create an nginx UI site, reverse proxy, loopback TCP listener, wildcard
listener, Docker port mapping, firewall chain, firewall rule, firewall script,
or systemd firewall service. SSH remains the only public administration entry
point and encrypts the UI transport.

`ocserv-ui` is one static Go binary with embedded HTML/CSS/JS. It runs as UID
`10001`, stores only hashed sessions and allowlisted audit events in an atomically
replaced JSON file, never mounts the Docker socket or ocserv configuration, and
runs with `network_mode: none`. It has no TCP listener, published port, or
Docker network. The SSH daemon reaches it only through the dedicated Unix
socket; the host runtime directory `/run/ocserv-ui-web` is owned by
`10001:10001` with mode `0700`, and `web.sock` is mode `0600`. Root SSH can
connect without broadening those filesystem permissions.

Reserve those numeric IDs with a host account and group both named
`ocserv-ui-host`. Require UID/GID `10001`, home `/nonexistent`, shell
`/usr/sbin/nologin`, a locked password, no supplementary groups, and no other
account using that UID or primary GID. Refuse installation if either name or
numeric ID is already allocated; never adopt or rewrite a colliding identity.
If installation rolls back, remove the user and then the group only when the
transaction created them and their exact identity is still verified.
`ocserv-control` is a compiled Go binary with no Python runtime. It has no
network, accepts only fixed JSON operations over a Unix socket, and mounts the
password database read-write. Share only the dedicated
occtl socket directory; never share `/run/ocserv`, which also contains the
security-module socket.

Ocserv invokes the managed `/etc/ocserv/session-journal.sh` for connect and
disconnect events. The script writes only validated, normalized JSONL fields
to `/var/log/ocserv/vpn-events.jsonl`; the host stores that file under
`/opt/ocserv-vps/logs`. Mount this directory read-write only in ocserv and
read-only in control. Do not expose the Docker socket or raw host logs to the
web process.

The control container runs as root with all capabilities dropped except
`DAC_OVERRIDE`. This one capability is required because ocserv creates the
shared `occtl.sock` as `ocserv:ocserv` mode `0711`; without it the otherwise
isolated sidecar cannot connect. Do not add `NET_ADMIN`, `SYS_ADMIN`, a network,
the Docker socket, or broader host mounts.

## Images and state

Publish two explicit version tags through `khorevaa/ocserv-vps/.github/workflows/publish-ui-images.yml`:

- `ghcr.io/khorevaa/ocserv-vps-ui:<version>`
- `ghcr.io/khorevaa/ocserv-vps-control:<version>`

The workflow accepts only a digest-pinned Go builder and the
explicit `ghcr.io/khorevaa/ocserv-vps:1.5.0` control base. It publishes
revision/version staging tags first, smoke-tests those exact artifacts, and
promotes the matched pair without overwriting a different version tag.

The final control stage is `scratch`. Its build copies only `occtl`,
`ocpasswd`, and their resolved shared libraries from the explicit ocserv tools
image; it must not copy that image's Python runtime or package database.

After the first publication, verify that both GHCR packages are public before
anonymous VPS installation. A private package requires Docker to be
pre-authenticated through a separately reviewed secret flow; never pass a PAT
as a command-line option to the installer.

Keep UI release variables in `/opt/ocserv-vps/ui.env` and the Compose override
in `/opt/ocserv-vps/compose.ui.yaml`. The base Compose helper automatically
includes them so an ocserv upgrade does not remove the UI as an orphan.
`ui.env` persists the generated browser hostname and local port. The hostname
must match `^ocserv-[0-9a-f]{32}\.localhost$`; generate it once per installation
and use it as the exact allowed `Host` and `Origin`.
Deploy and rollback refuse an ocserv tag that does not match the control
image's `org.ocserv-vps.ocserv-image` label; publish and install a compatible UI
release before changing the VPN image.

Persistent paths:

- `/opt/ocserv-vps/ui-data/state.json`: versioned JSON session/audit state, owned by UID `10001`, mode `0600`
- `/opt/ocserv-vps/ui-secrets`: root-owned session key and persistent access secret
- `/opt/ocserv-vps/ui-public`: public certificate chain plus an atomically refreshed state mirror
- `/opt/ocserv-vps/logs/vpn-events.jsonl`: bounded normalized VPN connect/disconnect journal, mode `0640`
- `/opt/ocserv-vps/locks/lifecycle.lock`: serializes CLI lifecycle operations
- `/opt/ocserv-vps/locks/operation.lock`: serializes CLI and UI mutations and service restart
- `/root/ocserv-vps-ui-access`: one-time access-secret handoff
- `/usr/local/sbin/ocserv-ui-access-info`: root-only (`0700`) URL/secret/tunnel display command

The access handoff contains the same exact `url=http://ocserv-<32hex>.localhost:<port>`
as `ui.env`. The random hostname is origin isolation, not a replacement for the
access secret.

Ephemeral path `/run/ocserv-ui-web/web.sock` is the only SSH-to-web transport.
Do not replace it with nginx, `127.0.0.1:8080`, a published Docker port, or an
internal Docker network.

## Security invariants

- Keep the fixed UI operator identity separate from VPN users.
- Require a distinct 256-bit access secret before serving the application or management API.
- Accept the secret only in the access form JSON body; never put it in a URL, environment variable, process argument, database, audit event, or access log.
- Exchange the secret directly for an opaque server-side session in a `__Host-` Secure/HttpOnly/SameSite=Strict cookie with a server-enforced maximum age of 12 hours.
- Bind session-token hashing to both the installation session key and current access secret so secret rotation invalidates every old session. Require exact Origin validation and CSRF for mutations.
- Never put passwords in URLs, process arguments, access logs, audit events, or
  the UI database.
- Generate VPN passwords in the control component and return each password once
  with `Cache-Control: no-store`.
- Reject an existing username during add and a missing username during rotation.
- Run `ocpasswd` with a fixed argument vector and passwords on standard input.
- Keep the control implementation in Go and retain `SO_PEERCRED`, request-size,
  command-timeout, output-size, file-type, and field-allowlist checks.
- Serialize user mutations with the shared lock and restore the password file
  from a root-only snapshot when `ocpasswd` or reload fails.
- Use `occtl terminate user` when rotation requests session invalidation.
- Use only `occtl disconnect id <validated integer>` for the connection action.
- Implement service restart through the fixed host-side
  `ocserv-vps-restart.path`/`ocserv-vps-restart.service` bridge. Control may
  create only `/run/ocserv-vps-actions/restart-ocserv`; the root-owned oneshot
  removes that trigger and runs `docker restart --timeout 10 ocserv-vps`.
  Never mount the Docker socket or accept a command, service name, or arguments
  from the browser.
- Allowlist every connection and journal response field; never return full raw
  `occtl` objects or arbitrary server-log lines.
- Do not expose firewall, certificate, image update, or arbitrary command
  operations through the MVP API.

## Installation gates

Run `scripts/install-ui.sh --dry-run` before mutation. Require restart approval
because installation recreates ocserv with a dedicated control-socket volume.
Do not require or perform a UI firewall change: the TCP listener exists only on
the controller after SSH forwarding; the VPS has no UI TCP listener.

Installation must:

1. verify both UI image component/version labels
2. snapshot Compose and config state
3. refuse any `ocserv-ui-host` name or UID/GID `10001` collision, then create
   and verify the locked nologin host identity
4. create the private `10001:10001` mode-`0700` socket directory
5. generate one `ocserv-<32hex>.localhost` hostname and persist the exact URL in
   `ui.env` and the root-only access handoff
6. activate the Compose override without exposing the Docker socket, a web
   container network, or a backend TCP port
7. require UI health directly over the Unix socket using the generated Host
8. require ocserv image/listener health
9. prove that the management API is hidden without a session
10. exchange the access secret directly for the operator session
11. add and rotate a temporary VPN user through the authenticated UI API and pass
   the OpenConnect tunneled HTTPS probe with both generated passwords
12. configure the managed VPN journal script and keep its mount read-only in control

Retrieve `/root/ocserv-vps-ui-access` over the independent SSH session, store it
in a password manager, and delete the handoff file. Run `scripts/ui-status.sh`, then run
the controller-side WSL/Linux OpenConnect test before closing SSH.
Later, a root SSH session may recover the same URL, current secret, and exact
tunnel command with `ocserv-ui-access-info`; its output is intentionally
sensitive and must not be redirected to shared logs.

Open the UI through a local TCP-to-remote-UDS SSH forward:

```bash
ssh -N -L 127.0.0.1:8765:/run/ocserv-ui-web/web.sock root@vpn.example.com
```

While the tunnel is active, open the exact random URL from `ui.env` or the
handoff, for example `http://ocserv-0123456789abcdef0123456789abcdef.localhost:8765/`.
Do not substitute literal `http://localhost:8765/`: its `Host` and `Origin` must
be rejected. The bundled `ui-tunnel.sh` and `ui-tunnel.ps1` helpers must read,
validate, and display the installed exact URL rather than synthesize one.
Do not expose the local forward on a non-loopback controller address. Enter the
access secret at the gate; successful exchange opens the operator session.

Rotate the access secret with `scripts/rotate-ui-access.sh --approve-restart`.
The script atomically replaces the root-owned file, recreates only `ocserv-ui`,
checks that the previous secret is rejected and the new secret succeeds over
the Unix socket, and restores the previous file if activation fails. A successful rotation
revokes all previously issued operator sessions.

## MVP API

- `GET /api/v1/overview`: allowlisted state, occtl status, counts, certificate
- `GET /api/v1/users`: usernames and active-session counts only
- `POST /api/v1/users`: add a unique VPN user
- `PUT /api/v1/users/{name}/password`: rotate password and optionally terminate sessions
- `GET /api/v1/connections`: allowlisted active occtl sessions
- `DELETE /api/v1/connections/{id}`: disconnect one validated active session
- `GET /api/v1/journal`: newest validated VPN connect/disconnect events only
- `POST /api/v1/service/restart`: CSRF-protected fixed ocserv restart; active VPN sessions disconnect

`POST /api/v1/access` is the authentication endpoint. It accepts only the
strict secret JSON body under exact Host and Origin checks, is reachable only
after SSH authentication, returns no secret, and sets only the opaque operator
session cookie.

User deletion/disable, UI operator management, and MFA remain follow-up scope.
The journal is the VPN server journal, not the panel's internal security audit.
The application offers system theme detection plus persistent light and dark
overrides without sending the preference to the server.

The MVP has no UI TCP port on the VPS and installs no nginx UI configuration or
UI firewall rules. Root-authenticated SSH forwarding is the first access
boundary; the high-entropy access secret, server-side sessions, CSRF, and audit
retention remain mandatory defense in depth.
