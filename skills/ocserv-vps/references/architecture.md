# Dockerized ocserv architecture

## Runtime topology

```text
Internet
  |-- TCP <vpn-port> --+
  `-- UDP <vpn-port> --+--> ocserv-vps container (host network)
                              |-- /dev/net/tun
                              |-- /opt/ocserv-vps/config -> /etc/ocserv (read-only)
                              `-- /etc/letsencrypt -> /etc/letsencrypt (read-only)

VPN client subnet --> host forwarding --> public interface --> NAT masquerade
```

Use `network_mode: host` because ocserv requires both TCP/TLS and UDP/DTLS and creates tunnel interfaces. Docker port publishing and an HTTP reverse proxy are not part of the default data path.

The container receives only `NET_ADMIN`, `NET_RAW`, and `/dev/net/tun`; do not switch to `privileged: true` without a reviewed requirement.

## Filesystem

- `/opt/ocserv-vps/compose.yaml`: fixed Compose definition
- `/opt/ocserv-vps/stack.env`: active immutable image tag
- `/opt/ocserv-vps/state`: current and previous versions/images
- `/opt/ocserv-vps/config/ocserv.conf`: generated configuration
- `/opt/ocserv-vps/config/ocpasswd`: mode `0600` password database
- `/opt/ocserv-vps/images/<version>-<sha>/`: pulled image reference, labels, and local image ID
- `/opt/ocserv-vps/bin/apply-network.sh`: idempotent network/firewall implementation
- `/var/backups/ocserv-vps/<timestamp>-<operation>`: root-only snapshots
- `/root/ocserv-vps-*-credentials`: short-lived root-only credential handoff files

## Image build and publication

Require two immutable inputs:

1. exact signed ocserv source release tuple
2. base image reference containing `@sha256:<digest>`

Verify the archive in GitHub Actions before it enters the Docker build context. Build the reviewed repository-root `docker/Dockerfile` and tag the result as:

```text
ocserv-vps:<version>-<first-12-source-sha>
```

Push the immutable tag to `ghcr.io/khorevaa/ocserv-vps` with SBOM and provenance. The VPS accepts only the resulting manifest digest and checks the version, source SHA, and base image OCI labels after pulling.

The current Dockerfile deliberately favors build reliability over minimal size: it compiles ocserv from source inside the pinned base image and retains the build/runtime packages. Introduce a multi-stage runtime image only after testing the full set of dynamically loaded authentication and networking libraries.

## Network and firewall

Bootstrap writes `ocserv-vps-network.service`. Its script owns dedicated chains:

- `OCSERV_VPS_INPUT`: established traffic, loopback, SSH, TCP 80, VPN TCP/UDP, ICMP; drop everything else
- `OCSERV_VPS_FORWARD`: permit the VPN subnet to the public interface and established return traffic; return unrelated forwarding to the host
- `OCSERV_VPS_NAT`: masquerade the VPN IPv4 subnet on the public interface

The IPv6 input chain permits established traffic, loopback, SSH, HTTP, and ICMPv6, then drops other inbound traffic. The generated ocserv config listens on IPv4 only until IPv6 address allocation and routing are deliberately implemented.

The bootstrap requires `--approve-firewall` because the restrictive input chain can block pre-existing services. Preserve independent SSH access until client testing succeeds.

## Certificates

Default mode uses Certbot standalone on TCP 80. `--prepare-nginx` instead creates an nginx port-80 ACME webroot site for the VPN domain. Both modes mount `/etc/letsencrypt` read-only into the container.

The deploy hook sends `SIGHUP` to the container after renewal and falls back to a restart.

## Transactions

### Bootstrap

Snapshot iptables/ip6tables and pre-existing managed network files before changing the firewall. On failure, stop the new stack and restore the saved firewall state. Docker packages, downloaded images, and ACME account state may remain for diagnosis.

### Upgrade

Pull the exact GHCR digest and config-test it before changing `stack.env`. Snapshot state, activate with Compose, compare the running image ID, and require TCP plus UDP listeners. Restore the old image automatically on failure.

### Rollback

Resolve a retained digest from pulled-image metadata, config-test it, snapshot current state, activate it, and apply the same health gates. Restore the image active at rollback start if the target fails.
