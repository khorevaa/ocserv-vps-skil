# Release sourcing and trust

Use this reference before running `deploy-release.sh`.

## Authoritative locations

Resolve releases from the official ocserv project and its official download page:

- upstream project: `https://gitlab.com/openconnect/ocserv`
- upstream website/download page: `https://ocserv.gitlab.io/www/download.html`

Do not use third-party mirrors, repackaged archives, random installer scripts, a branch snapshot, or a URL named `latest` for production deployment.

## Values to record

Record these as one immutable release tuple:

1. exact version string
2. exact HTTPS archive URL
3. exact archive SHA-256
4. exact HTTPS detached-signature URL
5. exact HTTPS signing-key URL published by upstream
6. full expected fingerprint for that signing key

A short key ID is not sufficient. Remove spaces only for comparison; do not truncate the fingerprint.

## Verification model

The deployment script performs all of these checks on the target host:

- HTTPS-only downloads with certificate validation
- exact SHA-256 match
- import into a temporary isolated GnuPG home
- exact imported-key fingerprint match
- detached-signature verification
- binding of the valid signature to the expected fingerprint
- archive path-safety checks before extraction

Both the digest and signature are required. The signature is the identity check; the digest also catches transfer mistakes and makes the requested artifact explicit.

## Release changes

Upstream build systems and optional dependencies can change. The script detects Meson or Autotools from the signed source tree and refuses unknown layouts. When a new release changes build prerequisites:

1. inspect official upstream build documentation and release notes
2. update the bundled dependency/build logic locally
3. run local syntax and validation checks
4. rerun preflight
5. deploy the same pinned artifact tuple

Do not add an unsigned fallback or install from the default branch to work around a release-format change.
