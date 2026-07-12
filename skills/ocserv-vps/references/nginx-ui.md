# nginx and management UI

## Current scope

Nginx is optional and is not part of the ocserv VPN data path.

When bootstrap receives `--prepare-nginx`, it:

- installs nginx if necessary
- creates `/var/www/ocserv-acme`
- creates a port-80 virtual host for the VPN domain
- serves only `/.well-known/acme-challenge/`
- returns `404` for every other path
- obtains the certificate with Certbot webroot mode

This mode creates no UI, authentication endpoint, or public management API.
The reviewed `install-ui.sh` transaction does not add nginx to the UI path.

## Port ownership

Ocserv owns the configured TCP and UDP VPN port, normally `443`. Do not copy an Xray/VLESS `grpc_pass` configuration: ocserv is not an HTTP or gRPC upstream and also requires UDP/DTLS.

The bundled MVP keeps ocserv on public `443` and creates no UI TCP listener on
the VPS. Operators map controller `127.0.0.1:8765` directly to
`/run/ocserv-ui-web/web.sock` with OpenSSH. Nginx does not proxy or terminate
the UI protocol.

Do not use generic nginx TLS termination in front of ocserv without an end-to-end protocol design. A generic nginx `stream` TCP/UDP proxy adds a network layer but does not provide the XHTTP routing behavior of the 3X-UI reference project.

## ACME migration

If bootstrap originally used Certbot standalone and nginx is added later, migrate certificate renewal to webroot or the nginx plugin before enabling nginx on port 80. Test `certbot renew --dry-run` and the ocserv reload hook.

## Implemented MVP security requirements

When exposing the bundled UI:

- create no nginx UI site, reverse proxy, or VPS UI TCP listener
- require `ssh -N -L 127.0.0.1:8765:/run/ocserv-ui-web/web.sock ...` and open
  only the exact random `http://ocserv-<32hex>.localhost:8765` URL stored in
  `ui.env` and the handoffs while the authenticated tunnel is active
- reject literal `http://localhost:8765`; require tunnel helpers to retrieve
  and validate the installed exact URL
- install no UI firewall chain, rule, script, or systemd firewall service
- run the application container with `network_mode: none`, publish no container
  port, and expose only `/run/ocserv-ui-web/web.sock`
- own the socket runtime directory as `10001:10001` mode `0700` and keep the
  socket mode `0600`; root OpenSSH can reach it without granting another group
- reserve UID/GID `10001` with the exact locked nologin `ocserv-ui-host`
  account/group, refuse all collisions, and remove only a transaction-created
  unchanged identity during rollback
- exchange the 256-bit access secret directly for the operator session
- require strong operator authentication and CSRF protection after the gate
- keep the 256-bit secret exchange behind SSH authentication
- keep the raw access secret out of URLs, application logs, Compose environment, and process arguments
- never expose Docker socket access to the UI
- never replace the Unix socket with `127.0.0.1:8080`, Docker port publishing,
  an internal Docker network, or an nginx proxy
- never pass VPN passwords through process arguments or logs
- keep state-changing UI actions behind bundled, validated server-side scripts
- add audit logging for supported user operations; do not expose firewall,
  certificate, or restart operations through the UI
