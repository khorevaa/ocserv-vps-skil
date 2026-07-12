[English](README.md) | [Русский](README_RU.md)

# Dockerized ocserv VPS skill

Bootstrap and operate a complete ocserv VPN on a fresh Debian or Ubuntu VPS. GitHub Actions builds an explicit [`docker/Dockerfile`](docker/Dockerfile) from a pinned, SHA-256 and GPG-verified source release and publishes it to `ghcr.io/khorevaa/ocserv-vps`. The skill deploys only an exact GHCR manifest digest, then configures certificates, users, forwarding, NAT, firewall, health checks, upgrades, and rollback.

The canonical installable bundle is [`skills/ocserv-vps/`](skills/ocserv-vps/).

## What it does

- inspects a fresh or managed VPS without changing it
- preserves an existing Docker Engine installation and installs Docker only when absent
- installs only a missing Compose v2 plugin when Docker already exists
- builds from an immutable base image digest instead of `latest`
- publishes immutable version-plus-source-SHA tags to GitHub Container Registry
- pulls only `ghcr.io/...@sha256:` references on the VPS
- obtains a Let's Encrypt certificate
- generates the initial ocserv configuration and password user
- enables IPv4 forwarding, restrictive ingress, VPN forwarding, and NAT
- runs ocserv with host networking, `/dev/net/tun`, `NET_ADMIN`, and `NET_RAW`
- checks the running image ID, configuration, and TCP/UDP listeners
- supports generated-password user creation, verified image upgrades, and rollback
- optionally prepares nginx on port 80 for ACME and a future UI without proxying ocserv

Bootstrap changes firewall policy and can interrupt SSH or VPN sessions if the wrong SSH port is supplied. Keep an independent SSH session open and review the dry-run plan first.

## Requirements

- root SSH access to Debian or Ubuntu
- `/dev/net/tun`
- public IPv4 and a domain resolving to the VPS
- an ocserv image published by the repository workflow from the exact source tuple and pinned base image
- public or pre-authenticated `ghcr.io/...@sha256:<digest>` image access
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
- [`bootstrap-vps.sh`](skills/ocserv-vps/scripts/bootstrap-vps.sh): complete fresh VPS deployment
- [`preflight.sh`](skills/ocserv-vps/scripts/preflight.sh): read-only host and stack inspection
- [`deploy-release.sh`](skills/ocserv-vps/scripts/deploy-release.sh): pull and activate a new verified GHCR digest
- [`rollback-release.sh`](skills/ocserv-vps/scripts/rollback-release.sh): activate a retained image with automatic restoration
- [`status.sh`](skills/ocserv-vps/scripts/status.sh): container, certificate, listener, network, and backup status
- [`add-user.sh`](skills/ocserv-vps/scripts/add-user.sh): generate and add a password user

Read [`skills/ocserv-vps/SKILL.md`](skills/ocserv-vps/SKILL.md) for the full operating procedure and safety gates.

## nginx

Nginx is optional preparation for a future UI. `--prepare-nginx` creates only a port-80 ACME webroot site. Ocserv still owns its TCP and UDP VPN port directly; nginx does not terminate or proxy the VPN protocol.

## Publishing an image

Run the `Publish ocserv image` workflow manually with the exact version, source URL, SHA-256, detached signature, signing key/fingerprint, and base image digest. Use the full manifest digest printed in the workflow summary for bootstrap or upgrades. Make the GHCR package public for unauthenticated fresh-VPS pulls.

## License

MIT. See [LICENSE](LICENSE).

The repository automation is MIT-licensed. Published container images include ocserv and its corresponding source tree under the upstream GPLv2-or-later terms.
