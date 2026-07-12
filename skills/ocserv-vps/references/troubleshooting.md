# Troubleshooting by stage

Use read-only inspection first:

```bash
./scripts/preflight.sh --host root@host --domain vpn.example.com
./scripts/status.sh --host root@host
```

## Docker installation

If Docker exists, the bootstrap must not replace it. Confirm:

```bash
docker version
docker compose version
systemctl status docker
```

When only Compose v2 is missing, install the plugin separately or extend the plugin package detection. Do not uninstall the existing engine.

## Source verification or image build

SHA, fingerprint, or signature failures are hard stops. Re-resolve the immutable artifact tuple from official sources.

For compile failure, inspect the GitHub Actions Docker build step. Common causes are a changed mandatory library, base-image package rename, or new Meson/Autotools requirement. Update only `docker/Dockerfile` and retry the same tuple.

The active container is unchanged until the exact published GHCR version tag is pulled and passes config validation.

## GHCR pull

Require an explicit `ghcr.io/<owner>/<image>:<version>` reference without `@sha256`. If a fresh VPS receives `denied`, confirm the package is public. Do not pass GitHub tokens through command-line arguments. For a private package, establish Docker authentication through a separately reviewed secret mechanism.

## ACME

Check:

```bash
getent ahostsv4 vpn.example.com
ss -ltnp | grep ':80 '
certbot certificates
```

Standalone mode requires TCP 80 to be free. Nginx preparation uses `/var/www/ocserv-acme` webroot instead. Do not stop an unrelated port-80 service without understanding it.

## Container startup

Check:

```bash
docker compose --project-directory /opt/ocserv-vps \
  --env-file /opt/ocserv-vps/stack.env \
  -f /opt/ocserv-vps/compose.yaml ps
docker logs --tail 100 ocserv-vps
docker inspect ocserv-vps
```

Confirm `/dev/net/tun`, `NET_ADMIN`, the config and certificate mounts, and that the running image ID matches the state file.

If OpenConnect reaches TCP 443 but TLS closes and container logs show `error connecting to sec-mod socket ... Permission denied`, confirm the Compose tmpfs for `/run/ocserv` uses mode `0755`. Docker tmpfs hides the image directory ownership; unprivileged workers need directory traversal while the socket keeps its own access controls.

## Listener or client failure

Check both protocols:

```bash
ss -ltnp | grep ':443 '
ss -lunp | grep ':443 '
iptables -S OCSERV_VPS_INPUT
iptables -S OCSERV_VPS_FORWARD
iptables -t nat -S OCSERV_VPS_NAT
sysctl net.ipv4.ip_forward
```

TCP without UDP means clients fall back from DTLS and performance suffers. A working listener with no internet access usually indicates forwarding, public-interface, or NAT mismatch.

## Mandatory OpenConnect probe

The deployment is not successful until the isolated probe authenticates and reaches the HTTPS target through `ocprobe0`. Check:

```bash
openconnect --version
test -x /usr/share/vpnc-scripts/vpnc-script || test -x /etc/vpnc/vpnc-script
ip netns list
docker logs --tail 100 ocserv-vps
```

The probe removes its namespace, veth pair, password file, and temporary user through exit traps. A leftover `ocsv-*` namespace indicates an interrupted cleanup; inspect it before deleting it. Certificate, authentication, tunnel-route, forwarding/NAT, or outbound HTTPS failures are hard deployment failures.

Keep the temporary executable `vpnc-script` wrapper under `/opt/ocserv-vps/bin`, not `/run`: Ubuntu may mount `/run` with `noexec`. Password and PID files remain under `/run`.

## Firewall lockout

Keep the original SSH session open during bootstrap. The managed input chain allows only the configured SSH port, HTTP/ACME, VPN TCP/UDP, ICMP, loopback, and established traffic.

If preflight found a nonstandard SSH port, pass the same value to `--ssh-port`. Do not guess.

Bootstrap snapshots iptables/ip6tables before applying its chains and restores them when bootstrap fails. The snapshot path is printed in operation output and stored under `/var/backups/ocserv-vps`.

## Upgrade or rollback failure

The script rewrites `stack.env` to the previous image and reruns Compose. Confirm state, expected image ID, TCP/UDP listeners, and container logs with `status.sh`.

Do not delete retained images or pulled-image metadata until a separate verified backup exists.
