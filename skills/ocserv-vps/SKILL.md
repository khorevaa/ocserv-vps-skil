---
name: ocserv-vps
description: Bootstrap, secure, operate, upgrade, and roll back a complete Dockerized ocserv VPN and its optional SSH-tunneled management UI on a root-managed Debian or Ubuntu VPS. Use when Codex must publish version-tagged ocserv or UI images to GitHub Container Registry, prepare a fresh VPS, install Docker only when absent, issue ACME certificates, configure forwarding/NAT/firewall, inspect health, manage VPN users, install the Unix-socket UI, change VPN passwords through the UI, upgrade images, or roll back. The workflow requires verified image inputs, explicit approval for applicable mutations, and real OpenConnect data-path checks.
---

# ocserv VPS

Deploy and operate a complete ocserv VPN stack through deterministic bundled scripts. Build and publish the ocserv image through the repository's reviewed GitHub Actions workflow, then deploy the explicit GHCR version tag to the VPS.

Treat this skill as manual-first. Bootstrap changes host networking and firewall policy. Deployment and rollback can disconnect active VPN sessions.

## Hard rules

- Execute every server-side mutation through the bundled scripts.
- Allow read-only SSH diagnosis, but never repair Docker, firewall, certificates, or ocserv configuration by hand.
- Run `preflight.sh` before bootstrap, upgrade, or rollback.
- Require explicit firewall approval for bootstrap or network changes and restart approval for container recreation; UI installation must not change the firewall.
- Install Docker Engine only when `docker` is absent. When Docker exists, preserve it and add only a missing Compose v2 plugin.
- Build every ocserv image from an exact HTTPS source archive after SHA-256, detached-signature, and full-fingerprint verification in GitHub Actions.
- Keep `docker/Dockerfile` explicit and reviewed. Publish `ghcr.io/khorevaa/ocserv-vps:<version>`.
- Deploy to the VPS only by an explicit version tag. Never deploy `latest` or a digest-qualified reference.
- Require successful OpenConnect authentication and a tunneled HTTPS request after bootstrap, upgrade, and rollback. Treat a failed probe as a failed deployment.
- Keep ocserv on host networking with TCP and UDP listeners; do not place HTTP `proxy_pass` or `grpc_pass` in front of it.
- Keep generated credentials out of summaries. Retrieve root-only credential files securely and delete them afterward.
- Never expose the Docker socket, ocserv sec-mod socket, or arbitrary host commands to the UI.
- Run both UI containers with `network_mode: none`; let root-authenticated OpenSSH reach the web container only through `/run/ocserv-ui-web/web.sock`, with no published backend port or internal Docker network.
- Create no UI TCP listener or nginx UI configuration on the VPS. Require `ssh -L 127.0.0.1:8765:/run/ocserv-ui-web/web.sock` for browser access and never add a UI firewall service/rule.
- Generate one `ocserv-<32hex>.localhost` hostname per installation, persist it in `ui.env` and the access handoff, and require that exact browser URL; reject literal `localhost`.
- Reserve host UID/GID `10001` with the exact locked nologin `ocserv-ui-host` account/group. Refuse every name or numeric-ID collision and remove the identity on rollback only if that transaction created it and it remains exact.
- Give the networkless root control sidecar only `DAC_OVERRIDE`, required to connect to ocserv's mode-0711 `occtl.sock`; drop every other capability.
- Exchange the separately generated UI access secret directly for the server-side operator session; never place that secret in a URL, Compose environment, process argument, or log.

## Supported host

Require all of the following:

- Debian or Ubuntu with `apt`, systemd, and root SSH access
- `/dev/net/tun`
- a public IPv4 address and a domain resolving to it
- independent SSH access while firewall and VPN services restart
- enough disk for Docker and at least two retained images

The default stack is IPv4-only. It assigns clients from `10.66.0.0/24`, enables IPv4 forwarding, and adds dedicated iptables chains for ingress, forwarding, and NAT.

## Required image-publish inputs

Collect before running `.github/workflows/publish-ocserv-image.yml`:

- exact ocserv version
- exact HTTPS source archive URL and SHA-256 digest
- exact HTTPS detached-signature URL
- exact HTTPS signing-key URL and full expected fingerprint
- Debian/Ubuntu base image reference containing an immutable `@sha256:` digest

The workflow verifies the source, builds the explicit repository-root `docker/Dockerfile`, and pushes `ghcr.io/khorevaa/ocserv-vps:<version>` to GHCR. Use that exact version tag.

## Required bootstrap inputs

Collect before VPS mutation:

- SSH target and actual SSH port
- public domain and ACME email
- initial VPN username; the server generates its password
- exact ocserv version matching the OCI label
- exact public or pre-authenticated `ghcr.io/<owner>/<image>:<version>` reference
- explicit acceptance that firewall policy will allow only established traffic, loopback, SSH, HTTP/ACME, ICMP, and the chosen VPN TCP/UDP port
- explicit acceptance that deployment can disconnect sessions

Read [`references/release-sourcing.md`](references/release-sourcing.md) before resolving the artifact tuple.

## Architecture

Use this fixed runtime shape:

- stack root: `/opt/ocserv-vps`
- published image: `ghcr.io/khorevaa/ocserv-vps:<version>`
- Compose service and container: `ocserv-vps`
- Docker networking: `network_mode: host`
- device: `/dev/net/tun`
- added capabilities: `NET_ADMIN`, `NET_RAW`
- configuration: `/opt/ocserv-vps/config`
- certificates: host `/etc/letsencrypt`, mounted read-only
- state and image metadata: `/opt/ocserv-vps/state` and `/opt/ocserv-vps/images`
- root-only backups: `/var/backups/ocserv-vps`
- persistent network service: `ocserv-vps-network.service`

Read [`references/architecture.md`](references/architecture.md) before changing container, port, or firewall behavior.

## Workflow

### 1. Inspect the VPS

Run:

```bash
./scripts/preflight.sh \
  --host root@vpn.example.com \
  --domain vpn.example.com \
  --target-version <version>
```

Treat these as blockers:

- unsupported OS
- missing `/dev/net/tun`
- insufficient independent SSH access
- occupied VPN port from an unexplained service
- domain without IPv4 resolution
- port 80 occupied when standalone ACME is selected
- existing unmanaged container named `ocserv-vps`
- incomplete managed state

### 2. Publish the version-tagged image

Run the `Publish ocserv image` GitHub Actions workflow with the exact release tuple and pinned base-image digest. Confirm the workflow summary contains `ghcr.io/khorevaa/ocserv-vps:<version>`. Ensure the GHCR package is public before unauthenticated fresh-VPS deployment, or pre-authenticate Docker separately.

### 3. Bootstrap a complete VPS

Run a dry plan first:

```bash
./scripts/bootstrap-vps.sh \
  --host root@vpn.example.com \
  --domain vpn.example.com \
  --acme-email admin@example.com \
  --vpn-username operator \
  --version <version> \
  --image ghcr.io/khorevaa/ocserv-vps:<version> \
  --approve-firewall \
  --approve-restart \
  --dry-run
```

Remove `--dry-run` only after reviewing the plan.

Add `--prepare-nginx` only when nginx should be installed for the ACME webroot. This mode creates only an HTTP port-80 ACME site returning `404` elsewhere. It does not proxy ocserv or the management UI.

Bootstrap must:

1. install required host tools
2. preserve an existing Docker installation or install Docker from the official APT repository only when absent
3. pull the exact GHCR version tag and validate its version, source-SHA, and base-image OCI labels
4. generate the ocserv configuration and password database
5. store initial credentials in `/root/ocserv-vps-initial-credentials` mode `0600`
6. snapshot firewall state
7. enable forwarding, NAT, and restrictive ingress rules through a persistent systemd service
8. issue or reuse the ACME certificate
9. validate the configuration inside the image
10. start Compose and require matching image ID plus TCP/UDP health checks
11. authenticate with OpenConnect from an isolated network namespace and require an HTTPS request routed through the tunnel

### 4. Verify and retrieve credentials

Run:

```bash
./scripts/status.sh --host root@vpn.example.com
```

Retrieve the initial VPN credentials over the independent SSH session, store them in a password manager, then delete the root-only file. Do not echo the password into chat summaries.

Test a real OpenConnect/AnyConnect-compatible client before closing the independent SSH session.

On a Linux controller or WSL2, pipe the password to `scripts/test-openconnect-client.sh --server <domain> --username <name>`. The script requires the route and HTTPS probe to traverse its temporary OpenConnect interface, then disconnects and removes its password file.

### 5. Add another user

Run:

```bash
./scripts/add-user.sh --host root@vpn.example.com --username phone
```

The script generates a new random password on the VPS, updates `ocpasswd`, signals the running container, and writes a root-only one-time credential file. When rotating the initial user, it removes the stale initial credential file.

### 6. Upgrade ocserv

Publish the new image through GitHub Actions, then run `deploy-release.sh` with its exact GHCR version tag. The script pulls and validates OCI labels without changing the active stack, tests the image against the current config and certificate, snapshots state, activates it through Compose, creates a temporary probe user, requires a successful OpenConnect tunnel and HTTPS request, deletes the probe user, and restores the previous image automatically on failure.

Never run `apt upgrade`, rewrite the VPN configuration, or prune the previous image as part of a release upgrade.

### 7. Roll back

Run:

```bash
./scripts/rollback-release.sh \
  --host root@vpn.example.com \
  --to-version previous \
  --approve-restart
```

Rollback must validate the retained image before activation, require the same temporary-user OpenConnect probe, and restore the image active at rollback start if any check fails.

## Dockerized management UI

Keep nginx outside the UI and VPN data paths. Keep ocserv on its configured TCP and UDP port and expose the UI only through `/run/ocserv-ui-web/web.sock`.

Keep both UI containers on `network_mode: none`; do not add nginx, publish a web
port, bind `127.0.0.1:8080`, or add an internal Docker network. Own the web
runtime directory as `10001:10001` mode `0700` and the socket as mode `0600`.
Back those numeric IDs with the locked `ocserv-ui-host` host account and group;
never reuse a pre-existing identity.

Read [`references/ui.md`](references/ui.md) and [`references/nginx-ui.md`](references/nginx-ui.md) before UI work. Publish the explicit UI and control images, then review a dry run:

```bash
./scripts/install-ui.sh \
  --host root@vpn.example.com \
  --ui-version <version> \
  --ui-image ghcr.io/khorevaa/ocserv-vps-ui:<version> \
  --control-image ghcr.io/khorevaa/ocserv-vps-control:<version> \
  --ui-port 8765 \
  --approve-restart \
  --dry-run
```

Remove `--dry-run` only after reviewing the controller-local UI port, container restart, and rollback snapshot. The UI transaction must not add a VPS TCP listener, nginx configuration, firewall rule, or service. Retrieve `/root/ocserv-vps-ui-access` securely, store the secret, delete the handoff file, and run `scripts/ui-status.sh`.

Create a local tunnel with `scripts/ui-tunnel.sh`, `scripts/ui-tunnel.ps1`, or `ssh -N -L 127.0.0.1:8765:/run/ocserv-ui-web/web.sock root@vpn.example.com`. Open only the exact `http://ocserv-<32hex>.localhost:8765/` URL from `ui.env` or the handoff; literal `http://localhost:8765/` is invalid. Require both helpers to retrieve, validate, and display that installed URL. Never bind the local forward beyond controller loopback. Enter the access secret in the dedicated form; successful exchange opens the operator session without another login.

When already connected to the VPS as root, run `ocserv-ui-access-info` to print
the exact URL, current access secret, and controller-side SSH tunnel command.
Treat its output as sensitive and never copy it into logs or chat.

Rotate a suspected or exposed access secret with `scripts/rotate-ui-access.sh --approve-restart`. This recreates only the web container, restores the old secret on failure, and invalidates every previous operator session on success.

Require the installation transaction to preserve direct VPN TCP/UDP ownership, keep the web container unprivileged, avoid the Docker socket, and pass both the server-side and controller-side OpenConnect probes.

## Failure handling

- Artifact verification or Docker build failure in GitHub Actions: do not deploy an image.
- GHCR pull or OCI-label failure: keep the active container unchanged.
- ACME failure: restore pre-bootstrap firewall state and do not start ocserv.
- Config validation failure: keep the active image unchanged.
- Health failure: restore the previous image and show container logs.
- OpenConnect authentication, tunnel-route, or HTTPS failure: remove the temporary probe user and restore the previous image.
- Unknown firewall or network topology: extend the bundled scripts; do not apply manual rules.

Read [`references/troubleshooting.md`](references/troubleshooting.md) for stage-specific checks.

## Script inventory

- `scripts/preflight.sh`: read-only host and stack inspection
- `scripts/bootstrap-vps.sh`: complete Dockerized VPS bootstrap
- `scripts/deploy-release.sh`: verified GHCR pull and transactional upgrade
- `scripts/rollback-release.sh`: retained-image rollback
- `scripts/status.sh`: container, listener, network, certificate, user, and backup status
- `scripts/add-user.sh`: generated-password user management
- `scripts/test-openconnect-client.sh`: controller-side OpenConnect tunnel and HTTPS data-path test
- `scripts/install-ui.sh`: transactional Unix-socket UI installation
- `scripts/ui-tunnel.sh` / `scripts/ui-tunnel.ps1`: controller-local SSH tunnel that retrieves and displays the exact installed random URL
- `scripts/rotate-ui-access.sh`: atomic UI access-secret rotation and operator-session revocation
- `scripts/ui-status.sh`: UI containers, private socket, local-tunnel contract, and handoff status
- `scripts/ssh-with-password.sh`: optional SSH password wrapper without `sshpass`
- `scripts/remote/`: bundled server-side implementations

## References

- [`references/architecture.md`](references/architecture.md): container, filesystem, network, firewall, and transaction model
- [`references/release-sourcing.md`](references/release-sourcing.md): immutable source and base-image trust chain
- [`references/nginx-ui.md`](references/nginx-ui.md): optional ACME nginx preparation and the rule that nginx stays outside the UI path
- [`references/ui.md`](references/ui.md): UI topology, security invariants, installation gates, and MVP API
- [`references/troubleshooting.md`](references/troubleshooting.md): diagnosis by deployment stage
