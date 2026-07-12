# Optional nginx and future UI

## Current scope

Nginx is optional and is not part of the ocserv VPN data path.

When bootstrap receives `--prepare-nginx`, it:

- installs nginx if necessary
- creates `/var/www/ocserv-acme`
- creates a port-80 virtual host for the VPN domain
- serves only `/.well-known/acme-challenge/`
- returns `404` for every other path
- obtains the certificate with Certbot webroot mode

No UI, authentication endpoint, or public management API is created.

## Port ownership

Ocserv owns the configured TCP and UDP VPN port, normally `443`. Do not copy an Xray/VLESS `grpc_pass` configuration: ocserv is not an HTTP or gRPC upstream and also requires UDP/DTLS.

Before adding a UI, choose and review one topology:

1. keep ocserv on `443` and publish the UI on another TLS port such as `8443`
2. move ocserv to another client port and give nginx public `443`
3. implement an ocserv-specific port-sharing/camouflage design supported by the chosen ocserv release
4. use a separate IP address for the UI edge

Do not use generic nginx TLS termination in front of ocserv without an end-to-end protocol design. A generic nginx `stream` TCP/UDP proxy adds a network layer but does not provide the XHTTP routing behavior of the 3X-UI reference project.

## ACME migration

If bootstrap originally used Certbot standalone and nginx is added later, migrate certificate renewal to webroot or the nginx plugin before enabling nginx on port 80. Test `certbot renew --dry-run` and the ocserv reload hook.

## UI security requirements

Before exposing a future UI:

- bind the application backend to loopback or a private Docker network
- require strong authentication and CSRF protection
- never expose Docker socket access to the UI
- never pass VPN passwords through process arguments or logs
- keep state-changing UI actions behind bundled, validated server-side scripts
- add audit logging and explicit operator confirmation for firewall, user, certificate, and restart operations
