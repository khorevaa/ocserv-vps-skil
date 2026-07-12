---
name: ocserv-vps
description: Deploy, migrate, upgrade, verify, and roll back version-pinned ocserv releases on root-managed Debian or Ubuntu VPS hosts from signed source archives while preserving an existing /etc/ocserv configuration. Use when Codex must inspect an ocserv host, adopt a package-managed ocserv service into a versioned /opt/ocserv layout, install a specific new upstream release, validate configuration and listeners, or switch back to a retained release after a failed or unwanted upgrade.
---

# ocserv VPS Releases

Operate an existing ocserv VPN host through deterministic bundled scripts. Keep the VPN configuration, certificates, user databases, routing, and firewall policy separate from the release binary lifecycle.

This skill is manual-first because every deployment or rollback restarts the VPN service and disconnects active users. Invoke it only when the operator explicitly asks to inspect, migrate, deploy, upgrade, or roll back ocserv.

## Hard rule

- Execute all server-side mutations only through the bundled scripts in this skill.
- Permit read-only SSH commands for diagnosis, but never edit remote files by hand, paste ad-hoc heredocs, or repair systemd/configuration directly over SSH.
- If a script encounters an unsupported host state, stop changing the server, patch the relevant bundled script locally, validate it, and rerun it.
- Never modify `/etc/ocserv`, certificates, authentication data, firewall rules, NAT rules, or sysctl settings as part of a release deployment.
- Never deploy a moving branch, `latest`, or an archive that has not passed the pinned SHA-256 and detached-signature checks.

## Supported host shape

Use this skill only when all of the following are true:

- the target is Debian or Ubuntu with `apt` and systemd
- SSH access is independent of the VPN being restarted
- a working ocserv configuration already exists, normally at `/etc/ocserv/ocserv.conf`
- the operator can provide an exact release version, source archive URL, detached signature URL, signing-key URL, full signing-key fingerprint, and SHA-256 digest
- the operator accepts that active VPN sessions will be disconnected during cutover

This skill does not bootstrap a new VPN policy from nothing. It preserves and validates an existing configuration while replacing only the ocserv release and its managed systemd unit.

## Required inputs

Collect before any write operation:

- SSH target, preferably `root@host`
- optional SSH port, identity file, or plain-text SSH password
- target ocserv version
- HTTPS source archive URL for that exact version
- archive SHA-256 digest
- HTTPS detached-signature URL
- HTTPS signing-key URL
- full expected signing-key fingerprint, not a short key ID
- existing config path if it is not `/etc/ocserv/ocserv.conf`
- existing service name, usually `ocserv.service`, for the first package-to-versioned migration

Read [`references/release-sourcing.md`](references/release-sourcing.md) before resolving release artifacts.

## Safety gates

Before deployment or rollback:

1. Confirm an out-of-band SSH session remains usable while ocserv is stopped.
2. Run preflight and inspect active sessions, service ownership, config validation, disk space, and the current binary.
3. Tell the operator that the restart disconnects active VPN users.
4. Require the explicit `--approve-restart` flag. Do not add it silently.
5. For a first migration from a distribution package, require `--adopt-existing-service <name>` instead of guessing which unit may be stopped or disabled.
6. Do not run `apt upgrade`, `apt full-upgrade`, distribution upgrades, firewall rewrites, or certificate renewal inside this workflow.

## Workflow

### 1. Inspect the host

Run the read-only preflight first:

```bash
./scripts/preflight.sh \
  --host root@vpn.example.com \
  --target-version <version>
```

Use the same SSH options on all scripts when needed:

```bash
--ssh-port 2222
--identity-file ~/.ssh/vpn_ed25519
--ssh-password 'temporary-password'
--accept-new-host-key
```

Treat these preflight results as blockers:

- `/etc/ocserv/ocserv.conf` is missing or fails validation with the current binary
- `ocserv.socket` is active
- another service owns the ocserv listener and no explicit adoption service was supplied
- the target version directory already exists
- there is not enough free space for a source build and retained rollback release
- SSH itself depends on the VPN path being restarted

### 2. Resolve and pin the release

Resolve artifacts only from the official upstream project or download page. Record all values explicitly. Do not let the deployment script discover “the newest” version.

The trust chain is:

1. exact HTTPS source archive
2. exact SHA-256 supplied by the operator
3. detached signature
4. signing key fetched from an explicit HTTPS URL
5. exact full fingerprint match before signature acceptance

If the upstream signing key or release format changes, update the local skill only after checking the official upstream documentation. Do not bypass signature verification as a quick fix.

### 3. Deploy a release

For the first migration from a package-managed service:

```bash
./scripts/deploy-release.sh \
  --host root@vpn.example.com \
  --version <version> \
  --source-url <https-source-archive> \
  --sha256 <64-hex-digest> \
  --signature-url <https-detached-signature> \
  --signing-key-url <https-signing-key> \
  --signing-key-fingerprint <full-fingerprint> \
  --adopt-existing-service ocserv.service \
  --approve-restart
```

For later upgrades, omit `--adopt-existing-service`:

```bash
./scripts/deploy-release.sh \
  --host root@vpn.example.com \
  --version <version> \
  --source-url <https-source-archive> \
  --sha256 <64-hex-digest> \
  --signature-url <https-detached-signature> \
  --signing-key-url <https-signing-key> \
  --signing-key-fingerprint <full-fingerprint> \
  --approve-restart
```

The deployment script must:

- lock against concurrent release operations
- install build dependencies without upgrading unrelated OS packages
- download and verify the exact archive and signing key
- build as an unprivileged local build user
- detect Meson or Autotools from the signed source tree
- install into `/opt/ocserv/releases/<version>` without activating it
- validate the new binary and existing config before cutover
- snapshot `/etc/ocserv`, the managed unit, service states, and the current symlink under `/var/backups/ocserv-release`
- atomically switch `/opt/ocserv/current`
- start `ocserv-release.service`
- verify systemd state, the running executable, and the configured TCP listener
- restore the previous release or adopted service automatically if activation fails

Read [`references/release-layout.md`](references/release-layout.md) for the transaction model.

### 4. Verify after deployment

Run:

```bash
./scripts/status.sh --host root@vpn.example.com
```

Confirm all of the following:

- `ocserv-release.service` is active
- `/opt/ocserv/current` points at the requested release
- the main process executable belongs to that release
- the new binary validates the existing config
- the configured TCP listener is present
- UDP/DTLS listener state is reported when configured
- `occtl show status` works when the control socket is available
- the previous release and backup remain available for rollback

A successful service restart is not sufficient by itself.

### 5. Roll back

Switch to a retained explicit version:

```bash
./scripts/rollback-release.sh \
  --host root@vpn.example.com \
  --to-version <retained-version> \
  --approve-restart
```

Use `--to-version previous` only when the state file reports a valid retained previous release.

Rollback validates the target binary against the current config before stopping the live service. If the target cannot start or pass health checks, the script restores the release that was active when rollback began.

## Failure handling

- Signature or fingerprint failure: stop. Re-resolve the artifacts from official upstream sources.
- Build failure: keep the active service unchanged, inspect the build output, patch dependency/build handling locally, then rerun.
- Config-test failure: keep the active service unchanged. Do not edit the production config as part of the release transaction.
- Activation failure: rely on the script's automatic rollback, then inspect the backup and journal output.
- Unexpected service topology: stop and extend the scripts. Do not disable units by hand.

Read [`references/troubleshooting.md`](references/troubleshooting.md) for focused checks.

## Decision rules

- Prefer a pinned source release over a moving branch or unversioned package source.
- Preserve `/etc/ocserv` as shared state across releases.
- Retain at least the current and previous release; do not auto-prune them during deployment.
- Treat a package-managed service as external state and adopt it only by explicit name.
- Refuse active socket-activated ocserv setups until the scripts are deliberately extended for them.
- Keep the managed service name fixed as `ocserv-release.service`.
- Keep release builds under `/opt/ocserv/releases` and activation through `/opt/ocserv/current`.
- Keep backups root-only because they may contain private keys and authentication material.
- Require a full signing-key fingerprint and detached signature even when HTTPS and SHA-256 checks pass.
- Do not expose SSH passwords in summaries or copy them into remote files.

## Script inventory

- [`scripts/preflight.sh`](scripts/preflight.sh): read-only host, config, listener, and service inspection
- [`scripts/deploy-release.sh`](scripts/deploy-release.sh): verified source build, transactional activation, health check, and automatic rollback
- [`scripts/rollback-release.sh`](scripts/rollback-release.sh): switch safely to a retained release
- [`scripts/status.sh`](scripts/status.sh): report release, service, config, listeners, state, and backups
- [`scripts/ssh-with-password.sh`](scripts/ssh-with-password.sh): optional SSH password wrapper without `sshpass`
- `scripts/remote/`: bundled server-side implementations; do not edit or replace them ad hoc on the target

## References

- [`references/release-sourcing.md`](references/release-sourcing.md): release trust and artifact resolution
- [`references/release-layout.md`](references/release-layout.md): paths, service ownership, transaction, and rollback invariants
- [`references/troubleshooting.md`](references/troubleshooting.md): diagnosis by failure stage
