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

For compile failure, inspect the `khorevaa/ocserv-vps` GitHub Actions Docker build step. Common causes are a changed mandatory library, base-image package rename, or new Meson/Autotools requirement. Update only that product repository's `docker/Dockerfile` and retry the same tuple.

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

For the controller-side WSL test, start a WSL shell and pipe the password from
Linux. Do not pipe a password from Windows PowerShell directly into `wsl.exe`:
some Windows PowerShell versions prepend an UTF-8 BOM to native stdin, changing
the password bytes. If automation must cross that boundary, write a BOM-free
file with user-only permissions, copy it to a root-only file under WSL `/run`,
redirect the test script's stdin from that file, and remove both copies in an
exit/finally handler. Never print the password while diagnosing this case.

Repeated failed probes can trigger ocserv's IP ban before authentication. Use
`occtl show ip bans` and `occtl show ip ban points` to distinguish a ban from a
bad password. Remove only the controller's confirmed IP with `occtl unban ip`
or wait for expiry; a restart resets in-memory test points but should not replace
normal ban handling.

## Firewall lockout

Keep the original SSH session open during bootstrap. The managed input chain allows only the configured SSH port, HTTP/ACME, VPN TCP/UDP, ICMP, loopback, and established traffic.

If preflight found a nonstandard SSH port, pass the same value to `--ssh-port`. Do not guess.

Bootstrap snapshots iptables/ip6tables before applying its chains and restores them when bootstrap fails. The snapshot path is printed in operation output and stored under `/var/backups/ocserv-vps`.

## UI unavailable

Run `scripts/ui-status.sh` first. Require both `ocserv-vps-ui` and
`ocserv-vps-control` to be healthy, `/run/ocserv-ui-web/web.sock` to be owned by
UID/GID `10001` with mode `0600`, and no UI TCP port to be published. Confirm
the SSH local forward is still running and open the exact randomized
`http://ocserv-<32hex>.localhost:<port>/` origin from `ui.env`; literal
`localhost` is rejected intentionally.

If overview or user operations return `control_unavailable`, inspect the two
dedicated runtime volumes and the control container log. The web container must
connect to `/run/ocserv-ui/control.sock` as UID `10001`; the control container
must reach `/run/ocserv-control/occtl.sock`. Never fix this by mounting the
Docker socket or the whole `/run/ocserv` directory into the web container.

If the access form rejects the stored secret, retrieve the current root-only
handoff if it still exists. Otherwise run
`scripts/rotate-ui-access.sh --approve-restart`; do not copy the persistent
`/opt/ocserv-vps/ui-secrets/access-secret` file into chat, shell arguments, or
logs. Rotation invalidates old access secrets and cookies but preserves UI
operators, VPN users, and the ocserv data path.

If the browser loses the response after creating a user, refresh the user list.
When the username exists but its one-time password was not received, rotate that
user's password and save the newly returned value. Plaintext VPN passwords are
never persisted for later retrieval, so repeating `add` cannot recover it.

## Upgrade or rollback failure

The script rewrites `stack.env` to the previous image and reruns Compose. Confirm state, expected image ID, TCP/UDP listeners, and container logs with `status.sh`.

Do not delete retained images or pulled-image metadata until a separate verified backup exists.
