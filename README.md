[English](README.md) | [Русский](README_RU.md)

# ocserv VPS release skill

Safely migrate, upgrade, inspect, and roll back an existing ocserv installation on a root-managed Debian or Ubuntu VPS.

The skill preserves `/etc/ocserv`, certificates, authentication data, routing, firewall rules, and sysctl settings. It replaces only the ocserv release and its managed systemd unit, using versioned releases under `/opt/ocserv`.

The canonical installable bundle is [`skills/ocserv-vps/`](skills/ocserv-vps/).

## Safety model

- exact release version and HTTPS artifact URLs
- required SHA-256 digest, detached signature, and full signing-key fingerprint
- read-only preflight before deployment
- build as an unprivileged account
- configuration validation before cutover
- operation locking, root-only backups, and atomic release switching
- service, executable, and listener health checks
- automatic restoration of the previous release or adopted service after activation failure

Deployments and rollbacks restart ocserv and disconnect active VPN sessions. The skill is manual-first and requires an explicit `--approve-restart` flag.

## Requirements

Operator workstation:

- Bash
- OpenSSH client
- independent SSH access to the VPS

Target VPS:

- Debian or Ubuntu with `apt` and systemd
- root access
- an existing, working ocserv configuration, normally `/etc/ocserv/ocserv.conf`
- enough disk space to build a release and retain a rollback release

This skill does not create a new VPN configuration or firewall policy from scratch.

## Install in Codex

Use the built-in skill installer:

```text
$skill-installer install https://github.com/khorevaa/ocserv-vps-skil/tree/develop/skills/ocserv-vps
```

Then invoke it explicitly:

```text
$ocserv-vps inspect my existing ocserv host before an upgrade
```

## Workflows

The bundle provides four operator workflows:

1. `preflight.sh` inspects the host, current configuration, services, listeners, sessions, disk space, and target release path without changing the VPS.
2. `deploy-release.sh` verifies and builds a pinned source release, snapshots the current state, switches releases, validates health, and automatically restores the previous state on failure.
3. `status.sh` reports the managed service, active binary, retained releases, listeners, state, and backups.
4. `rollback-release.sh` validates and activates a retained release, restoring the original release if rollback health checks fail.

Detailed operating instructions are in [`skills/ocserv-vps/SKILL.md`](skills/ocserv-vps/SKILL.md).

## Repository layout

- [`skills/ocserv-vps/SKILL.md`](skills/ocserv-vps/SKILL.md): canonical skill instructions
- [`skills/ocserv-vps/scripts/`](skills/ocserv-vps/scripts/): local entrypoints and bundled remote implementations
- [`skills/ocserv-vps/references/`](skills/ocserv-vps/references/): release sourcing, transaction, and troubleshooting references
- [`skills/ocserv-vps/agents/openai.yaml`](skills/ocserv-vps/agents/openai.yaml): Codex/OpenAI interface metadata

## License

MIT. See [LICENSE](LICENSE).
