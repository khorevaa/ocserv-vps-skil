# Versioned release layout and transaction

## Paths

- releases: `/opt/ocserv/releases/<version>`
- active symlink: `/opt/ocserv/current`
- shared config and credentials: `/etc/ocserv`
- managed unit: `/etc/systemd/system/ocserv-release.service`
- managed state: `/var/lib/ocserv-release/state`
- root-only snapshots: `/var/backups/ocserv-release/<timestamp>-<operation>`
- operation lock: `/run/lock/ocserv-release.lock`

The release directories contain only built software and release metadata. `/etc/ocserv` remains shared and is never rewritten by the release scripts.

## Build isolation

The target archive is verified before extraction. Compilation and staged installation run as the unprivileged `_ocservbuild` account. The compiled prefix is the final versioned release path, while `DESTDIR` keeps installation inactive until files are copied into `/opt/ocserv/releases/<version>`.

A release directory is immutable after creation. A repeated deployment of the same version is refused rather than overwriting an artifact that may be needed for rollback.

## First adoption

A distribution unit such as `ocserv.service` is external state. The first migration requires its exact name through `--adopt-existing-service`.

The script records whether that service was active and enabled, snapshots its unit text, and changes it only during cutover. If the new release cannot activate, the script restores the old service's previous active/enabled state.

Socket activation is intentionally unsupported because switching a socket/service pair safely needs a separate transaction design.

## Cutover transaction

Before any service stop, the script:

1. builds the target release outside the active path
2. runs the new binary's config test against the existing config
3. snapshots `/etc/ocserv`, current symlink, unit, state, and service flags
4. writes the managed unit and reloads systemd

Only then does it:

1. stop the current managed or explicitly adopted service
2. disable the adopted service when it was enabled
3. atomically replace `/opt/ocserv/current`
4. enable and start `ocserv-release.service`
5. wait for systemd, executable-path, and TCP-listener checks

A health-check failure restores the prior symlink/unit and service states. After the prior state is restored, the failed target release is removed so the same pinned deployment can be retried; the root-only snapshot and command diagnostics remain available.

## Manual rollback

`rollback-release.sh` first validates the selected retained binary against the current config. It snapshots state, stops the managed service, switches the symlink, starts the target, and runs the same health check.

If the rollback target fails, the script switches back to the release that was active when rollback began.

## Invariants

- only one release operation can hold the lock
- the active symlink always points at a complete release or is restored
- a release is never activated before signature, build, and config validation
- a successful systemd command is not considered sufficient without process and listener checks
- current and previous versions remain on disk
- private configuration backups are mode `0700`
