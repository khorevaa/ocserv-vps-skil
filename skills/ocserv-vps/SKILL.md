---
name: ocserv-vps
description: Bootstrap, secure, operate, upgrade, and roll back a complete Dockerized ocserv VPN on a root-managed Debian or Ubuntu VPS. Use when Codex must publish a version-tagged ocserv image to GitHub Container Registry from a SHA-256 and GPG-verified source release, prepare a fresh VPS, install Docker only when absent, pull an explicit GHCR version tag, issue an ACME certificate, generate the ocserv configuration and first user, configure forwarding/NAT/firewall, inspect health, add users, upgrade the image, or roll back to a retained image. Optionally prepare nginx as the HTTP/ACME edge for a future UI without proxying ocserv.
---

# ocserv VPS

Deploy and operate a complete ocserv VPN stack through deterministic bundled scripts. Build and publish the ocserv image through the repository's reviewed GitHub Actions workflow, then deploy the explicit GHCR version tag to the VPS.

Treat this skill as manual-first. Bootstrap changes host networking and firewall policy. Deployment and rollback can disconnect active VPN sessions.

## Hard rules

- Execute every server-side mutation through the bundled scripts.
- Allow read-only SSH diagnosis, but never repair Docker, firewall, certificates, or ocserv configuration by hand.
- Run `preflight.sh` before bootstrap, upgrade, or rollback.
- Require explicit firewall and restart approvals; never add them silently.
- Install Docker Engine only when `docker` is absent. When Docker exists, preserve it and add only a missing Compose v2 plugin.
- Build every ocserv image from an exact HTTPS source archive after SHA-256, detached-signature, and full-fingerprint verification in GitHub Actions.
- Keep `docker/Dockerfile` explicit and reviewed. Publish `ghcr.io/khorevaa/ocserv-vps:<version>`.
- Deploy to the VPS only by an explicit version tag. Never deploy `latest` or a digest-qualified reference.
- Require successful OpenConnect authentication and a tunneled HTTPS request after bootstrap, upgrade, and rollback. Treat a failed probe as a failed deployment.
- Keep ocserv on host networking with TCP and UDP listeners; do not place HTTP `proxy_pass` or `grpc_pass` in front of it.
- Keep generated credentials out of summaries. Retrieve root-only credential files securely and delete them afterward.

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

Add `--prepare-nginx` when nginx should be installed now for ACME webroot and future UI work. This mode creates only an HTTP port-80 ACME site returning `404` elsewhere. It does not proxy ocserv and does not expose a UI.

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

Retrieve the initial credentials over the independent SSH session, store them in a password manager, then delete the root-only file. Do not echo the password into chat summaries.

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

## nginx and future UI

Treat nginx as optional preparation, not part of the VPN data path. Ocserv owns its configured TCP and UDP port directly.

Read [`references/nginx-ui.md`](references/nginx-ui.md) before adding a UI. Decide explicitly whether the UI uses another TLS port, ocserv moves ports, or a reviewed ocserv-compatible port-sharing design is introduced. Do not copy the Xray `grpc_pass` topology.

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
- `scripts/ssh-with-password.sh`: optional SSH password wrapper without `sshpass`
- `scripts/remote/`: bundled server-side implementations

## References

- [`references/architecture.md`](references/architecture.md): container, filesystem, network, firewall, and transaction model
- [`references/release-sourcing.md`](references/release-sourcing.md): immutable source and base-image trust chain
- [`references/nginx-ui.md`](references/nginx-ui.md): optional nginx preparation and future UI constraints
- [`references/troubleshooting.md`](references/troubleshooting.md): diagnosis by deployment stage
