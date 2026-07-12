[English](README.md) | [Русский](README_RU.md)

# Dockerized ocserv VPS skill

Bootstrap and operate a complete ocserv VPN on a fresh Debian or Ubuntu VPS. GitHub Actions builds an explicit [`docker/Dockerfile`](docker/Dockerfile) from a pinned, SHA-256 and GPG-verified source release and publishes it to `ghcr.io/khorevaa/ocserv-vps`. The skill deploys the version tag `ghcr.io/khorevaa/ocserv-vps:<version>`, then configures certificates, users, forwarding, NAT, firewall, health checks, upgrades, and rollback.

The canonical installable bundle is [`skills/ocserv-vps/`](skills/ocserv-vps/).

## What it does

- inspects a fresh or managed VPS without changing it
- preserves an existing Docker Engine installation and installs Docker only when absent
- installs only a missing Compose v2 plugin when Docker already exists
- builds from an immutable base image digest instead of `latest`
- publishes version tags such as `ghcr.io/khorevaa/ocserv-vps:1.5.0` to GitHub Container Registry
- pulls only explicit version tags from GHCR; `latest` is not used
- obtains a Let's Encrypt certificate
- generates the initial ocserv configuration and password user
- enables IPv4 forwarding, restrictive ingress, VPN forwarding, and NAT
- runs ocserv with host networking, `/dev/net/tun`, `NET_ADMIN`, and `NET_RAW`
- checks the running image ID, configuration, and TCP/UDP listeners
- requires a real OpenConnect login and tunneled HTTPS request from an isolated network namespace after bootstrap, upgrade, and rollback
- includes a controller-side OpenConnect test for Linux or WSL2
- optionally installs a Dockerized management UI for server overview, user creation, and password rotation
- supports generated-password user creation, verified image upgrades, and rollback
- optionally prepares nginx on port 80 for ACME only, outside both VPN and UI paths

Bootstrap changes firewall policy and can interrupt SSH or VPN sessions if the wrong SSH port is supplied. Keep an independent SSH session open and review the dry-run plan first.

## Requirements

- root SSH access to Debian or Ubuntu
- `/dev/net/tun`
- public IPv4 and a domain resolving to the VPS
- an ocserv image published by the repository workflow from the exact source tuple and pinned base image
- public or pre-authenticated access to `ghcr.io/khorevaa/ocserv-vps:<version>`
- enough disk space to retain at least two images

## Install in Codex

```text
$skill-installer install https://github.com/khorevaa/ocserv-vps-skil/tree/develop/skills/ocserv-vps
```

Invoke it explicitly:

```text
$ocserv-vps bootstrap a complete Dockerized ocserv VPN on my VPS
```

## Main workflows

- [Publish ocserv image](.github/workflows/publish-ocserv-image.yml): verify source, build the explicit Dockerfile, and push to GHCR
- [Publish ocserv UI images](.github/workflows/publish-ui-images.yml): test and publish revision-matched web/control images to GHCR
- [`bootstrap-vps.sh`](skills/ocserv-vps/scripts/bootstrap-vps.sh): complete fresh VPS deployment
- [`preflight.sh`](skills/ocserv-vps/scripts/preflight.sh): read-only host and stack inspection
- [`deploy-release.sh`](skills/ocserv-vps/scripts/deploy-release.sh): pull, activate, and OpenConnect-test a new GHCR version
- [`rollback-release.sh`](skills/ocserv-vps/scripts/rollback-release.sh): activate a retained image with automatic restoration
- [`status.sh`](skills/ocserv-vps/scripts/status.sh): container, certificate, listener, network, and backup status
- [`add-user.sh`](skills/ocserv-vps/scripts/add-user.sh): generate and add a password user
- [`test-openconnect-client.sh`](skills/ocserv-vps/scripts/test-openconnect-client.sh): local Linux/WSL tunnel and HTTPS data-path test
- [`install-ui.sh`](skills/ocserv-vps/scripts/install-ui.sh): transactional Unix-socket UI installation
- [`ui-tunnel.sh`](skills/ocserv-vps/scripts/ui-tunnel.sh) / [`ui-tunnel.ps1`](skills/ocserv-vps/scripts/ui-tunnel.ps1): controller-local SSH tunnel that retrieves and displays the exact installed random URL
- [`rotate-ui-access.sh`](skills/ocserv-vps/scripts/rotate-ui-access.sh): rotate the UI access secret and revoke operator sessions
- [`ui-status.sh`](skills/ocserv-vps/scripts/ui-status.sh): UI containers, private socket, tunnel contract, and handoff status

Read [`skills/ocserv-vps/SKILL.md`](skills/ocserv-vps/SKILL.md) for the full operating procedure and safety gates.

## nginx

Nginx remains outside both the VPN and UI data paths. `--prepare-nginx` creates only the ACME webroot. Ocserv still owns its TCP and UDP VPN port directly, while the UI exposes only `/run/ocserv-ui-web/web.sock` on the VPS.

The networkless UI container publishes no Docker port and uses neither
`127.0.0.1:8080`, an internal Docker network, nor an nginx proxy.

The UI is not public and adds no VPS TCP listener, nginx configuration,
firewall rule, or service. Connect with
`ssh -N -L 127.0.0.1:8765:/run/ocserv-ui-web/web.sock root@vpn.example.com`
or use the bundled `ui-tunnel` helper, then open the exact
`http://ocserv-<32hex>.localhost:8765/` URL recorded in `ui.env` and the
root-only handoffs. Never substitute literal `http://localhost:8765/`; the
helpers retrieve, validate, and display the installed URL.

Installation reserves host UID/GID `10001` as the locked nologin account and
group `ocserv-ui-host`. Any existing name or numeric-ID collision aborts the
transaction; rollback removes only the unchanged identity it created.

The UI MVP uses one separately generated access secret. It shows server, certificate, connection, and user counts; lists VPN users; creates users; and rotates generated passwords with optional session termination. The secret is entered in a dedicated form, never placed in a URL, and exchanged directly for an opaque server-side operator session valid for at most 12 hours.

Both UI services are compiled Go binaries. The unprivileged web process stores
only versioned JSON state, while the isolated control sidecar keeps the fixed
Unix-socket protocol and invokes `occtl`/`ocpasswd` without a shell. Neither
container includes Python, SQLite, or a database service.

From a root SSH session, run `ocserv-ui-access-info` to display the exact local URL, current secret, and ready-to-run SSH tunnel command. Its output is sensitive.

## Publishing an image

Run the `Publish ocserv image` workflow manually with the exact version, source URL, SHA-256, detached signature, signing key/fingerprint, and base image digest. Use the version tag printed in the workflow summary for bootstrap or upgrades. Make the GHCR package public for unauthenticated fresh-VPS pulls.

## License

MIT. See [LICENSE](LICENSE).

The repository automation is MIT-licensed. Published container images include ocserv and its corresponding source tree under the upstream GPLv2-or-later terms.
