# Troubleshooting by stage

Use read-only inspection first. Never repair the production host manually; patch the bundled script and rerun.

## Preflight

Run:

```bash
./scripts/preflight.sh --host root@host --target-version <version>
./scripts/status.sh --host root@host
```

Block deployment when the config is unreadable, current config validation fails, `ocserv.socket` is active, the target path exists, or the active service is not explicitly understood.

## Download or signature failure

Symptoms include HTTPS errors, SHA mismatch, unknown fingerprint, or a bad detached signature.

Actions:

- re-resolve the artifact tuple from official upstream locations
- verify that the full fingerprint, not a short ID, was copied
- check target-host clock and CA trust
- do not disable signature checks

The live service is not touched at this stage.

## Dependency or build failure

The live service is still unchanged. Inspect the final Meson/Autotools diagnostics in the command output.

Common causes:

- a new mandatory development library
- a renamed Debian/Ubuntu package
- an upstream Meson option or minimum Meson version change
- insufficient memory or disk space

Update only `scripts/remote/deploy-release.sh`, run syntax validation, and retry the same pinned release.

## Config-test failure

The new release was built but rejected the existing config. The inactive target directory is removed so the same pinned deployment can be retried after the issue is understood.

Do not alter production configuration inside the release transaction. Review upstream release notes and decide separately whether the config itself needs a controlled migration.

## Activation failure

The deployment script prints systemd status and recent journal lines, then restores the previous release or explicitly adopted service.

Check:

```bash
./scripts/status.sh --host root@host
```

Confirm the current symlink, service active state, running executable, TCP listener, backup path, and retained releases.

## Service active but listener missing

Check the parsed `tcp-port`, binding directives, certificate/key paths, and recent journal output. A listener check failure triggers automatic rollback even when systemd briefly reports `active`.

UDP absence is reported as a warning because DTLS may be disabled; TCP is the activation gate.

## `occtl` unavailable

The control socket may be disabled, moved, or inaccessible. `occtl` output is supplemental; activation still requires systemd, executable-path, and TCP-listener checks.

## Rollback target rejects config

The rollback script refuses to stop the live service. Select a different retained release or perform a separate reviewed config migration before trying again.

## Recovering from an interrupted SSH session

Reconnect over independent SSH and run `status.sh`. The remote operation lock is tied to the running process; do not start a competing deployment while the original process is still active. Inspect `/opt/ocserv/current`, `ocserv-release.service`, the state file, and the newest root-only backup before deciding whether to rerun deployment or explicit rollback.
