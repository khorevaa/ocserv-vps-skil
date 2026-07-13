[English](README.md) | [Русский](README_RU.md)

# Codex skill for ocserv-vps

This repository contains the installable Codex skill that bootstraps and operates a Dockerized ocserv VPN and its private SSH-tunneled management UI on Debian or Ubuntu VPS hosts.

Product code, container builds, UI sources, the standalone installer, and GHCR publishing workflows live in [`khorevaa/ocserv-vps`](https://github.com/khorevaa/ocserv-vps). This repository intentionally keeps only Codex instructions, controller-side automation, and the server-side tasks streamed over SSH by the skill.

## Install the skill

```text
$skill-installer install https://github.com/khorevaa/ocserv-vps-skil/tree/develop/skills/ocserv-vps
```

Invoke it explicitly:

```text
$ocserv-vps bootstrap a complete Dockerized ocserv VPN on my VPS
```

## What the skill automates

- read-only VPS preflight and status inspection
- Docker-preserving bootstrap with ACME, forwarding, NAT, and restrictive firewall rules
- verified explicit-version image deployment from `ghcr.io/khorevaa/ocserv-vps`
- real OpenConnect authentication and tunneled HTTPS checks
- generated-password VPN user management
- transactional ocserv upgrades and rollback
- private Unix-socket UI installation, upgrades, access-secret rotation, status, and SSH tunnel helpers

Bootstrap changes firewall policy and may interrupt SSH or VPN sessions. Keep an independent SSH session open, run the dry-run plan first, and provide explicit firewall/restart approval.

## Product repository

Use [`khorevaa/ocserv-vps`](https://github.com/khorevaa/ocserv-vps) for:

- `docker/` and the verified ocserv image build
- `ui/web/` and `ui/control/`
- the standalone `install.sh` and `ocserv-vps` server manager
- GHCR publishing workflows and product releases

The skill must accept UI images only when their OCI source label is `https://github.com/khorevaa/ocserv-vps`.

## License

MIT. See [LICENSE](LICENSE).
