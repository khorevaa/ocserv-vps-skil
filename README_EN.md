[Русский](README.md) | [English](README_EN.md)

# ocserv VPS skill

A focused Codex skill for deploying and operating [khorevaa/ocserv-vps](https://github.com/khorevaa/ocserv-vps) on a Debian or Ubuntu VPS.

The runtime, Docker images, firewall and certificate automation, release transactions, and web UI now live in the `ocserv-vps` repository. This repository contains only the AI workflow that inspects a host, installs a pinned release of the manager, deploys the VPN, verifies it, and optionally installs the private UI.

## Capabilities

- read-only VPS preflight over SSH
- pinned stable manager installation
- unattended VPN deployment with explicit firewall and restart gates
- status, logs, users, updates, rollback, and uninstall through `ocserv-vps`
- optional private UI installation and updates
- safe handoff of VPN and UI credentials without placing secrets in chat

The UI is opt-in. A normal deployment installs only the VPN unless the user explicitly asks for the panel.

## Install in Codex

```text
$skill-installer install https://github.com/khorevaa/ocserv-vps-skil/tree/develop/skills/ocserv-vps
```

Example requests:

```text
$ocserv-vps deploy the VPN on my VPS
$ocserv-vps deploy the VPN and the private management UI
$ocserv-vps check the server and update ocserv
```

Read [the skill instructions](skills/ocserv-vps/SKILL.md) for the workflow and safety gates.

## Scope

Do not add ocserv builds, Dockerfiles, server-side deployment scripts, or UI source code here. Make those changes in [khorevaa/ocserv-vps](https://github.com/khorevaa/ocserv-vps); keep this repository as the thin AI orchestration layer.

## License

MIT. See [LICENSE](LICENSE).
