# Source, Dockerfile, and GHCR trust

## GHCR publication workflow

Use `.github/workflows/publish-ocserv-image.yml` as the only supported image publisher. It prepares a verified build context with `docker/prepare-context.sh`, builds the explicit `docker/Dockerfile`, and pushes to `ghcr.io/khorevaa/ocserv-vps` with provenance and SBOM enabled.

The workflow uses the repository `GITHUB_TOKEN` with `packages: write`; do not copy a GHCR token to the VPS. New GHCR packages may be private by default. Make the package public for anonymous deployment, or pre-authenticate Docker through a separate reviewed secret flow.

## ocserv release tuple

Resolve release artifacts only from the official ocserv project and download locations:

- `https://gitlab.com/openconnect/ocserv`
- `https://ocserv.gitlab.io/www/download.html`

Record one immutable tuple:

1. exact version
2. exact HTTPS archive URL
3. exact archive SHA-256
4. exact HTTPS detached-signature URL
5. exact HTTPS signing-key URL
6. full expected signing-key fingerprint

The workflow verifies HTTPS, SHA-256, an isolated GnuPG import, the full fingerprint, the detached signature, and the binding of the valid signature to the expected fingerprint. It checks archive paths and links before extraction.

Do not use branch snapshots, `latest`, third-party installer scripts, unsigned mirrors, short key IDs, or a digest copied from the same untrusted mirror as the archive.

## Base image

Pass an official Debian or Ubuntu image reference with an immutable manifest digest to the workflow, for example:

```text
debian:bookworm-slim@sha256:<64-hex-digest>
```

Resolve the current digest from the official image registry immediately before deployment. Record it with the release tuple. A tag without `@sha256:` is rejected.

The base digest pins the image filesystem but not future results of `apt-get update` inside a rebuild. The GHCR tag contains only the ocserv version and can be replaced by a later workflow run for that version; the verified source SHA remains recorded in the OCI label. For fully reproducible package inputs, add a reviewed Debian/Ubuntu snapshot repository and pinned package versions in a later change.

## Docker Engine

When Docker is absent, install Docker Engine from Docker's official APT repository. When Docker already exists, preserve it. If Compose v2 is missing, install only an available Compose plugin package; never remove or replace the existing engine implicitly.

Do not use the Docker convenience script for production bootstrap.

## Release changes

When an ocserv release changes build dependencies or build systems:

1. inspect official release notes and build instructions
2. update the explicit `docker/Dockerfile`
3. run syntax and render checks
4. run preflight
5. rerun the publisher with the same immutable tuple

Never weaken signature or digest verification to work around a build failure.
