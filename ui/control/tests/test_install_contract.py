from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


class InstallComposeContractTests(unittest.TestCase):
    @staticmethod
    def _installer_cookie_parser(installer: str) -> str:
        function = installer.split("write_ui_cookie_header() {\n", 1)[1]
        return function.split("<<'PY'\n", 1)[1].split("\nPY\n}", 1)[0]

    def test_ui_compose_uses_only_unix_sockets_and_required_capability(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        installer = (
            repository
            / "skills"
            / "ocserv-vps"
            / "scripts"
            / "remote"
            / "install-ui.sh"
        ).read_text(encoding="utf-8")
        remote_common = (
            repository
            / "skills"
            / "ocserv-vps"
            / "scripts"
            / "remote"
            / "common.sh"
        ).read_text(encoding="utf-8")

        compose_contract = installer.split(
            'cat > "${OCSERV_UI_COMPOSE_FILE}" <<EOF\n', 1
        )[1].split('\nEOF\nchmod 0640 "${OCSERV_UI_COMPOSE_FILE}"', 1)[0]
        control_block = compose_contract.split("  ocserv-control:\n", 1)[1].split(
            "\n  ocserv-ui:\n", 1
        )[0]
        self.assertIn("network_mode: none", control_block)
        self.assertIn("cap_drop:\n      - ALL", control_block)
        self.assertIn("cap_add:", control_block)
        self.assertIn("- DAC_OVERRIDE", control_block)
        self.assertNotIn("NET_ADMIN", control_block)
        self.assertNotIn("SYS_ADMIN", control_block)
        self.assertNotIn("docker.sock", control_block)
        self.assertIn("OCSERV_UI_JOURNAL_FILE: /opt/ocserv-vps/logs/vpn-events.jsonl", control_block)
        self.assertIn("- ./logs:/opt/ocserv-vps/logs:ro", control_block)
        self.assertIn("source: ${OCSERV_UI_ACTION_DIR}", control_block)
        self.assertIn("target: ${OCSERV_UI_ACTION_DIR}", control_block)

        web_block = compose_contract.split("\n  ocserv-ui:\n", 1)[1].split(
            "\nvolumes:\n", 1
        )[0]
        self.assertIn("network_mode: none", web_block)
        self.assertIn("cap_drop:\n      - ALL", web_block)
        self.assertNotIn("cap_add:", web_block)
        self.assertNotIn("group_add:", web_block)
        self.assertIn("OCSERV_UI_WEB_SOCKET: ${UI_WEB_SOCKET}", web_block)
        self.assertIn("OCSERV_UI_JSON: /var/lib/ocserv-ui/state.json", web_block)
        self.assertNotIn("OCSERV_UI_DB", web_block)
        self.assertIn(
            'OCSERV_UI_ALLOWED_ORIGIN: "http://${UI_LOCAL_HOST}:${UI_PORT}"',
            web_block,
        )
        self.assertIn("- type: bind", web_block)
        self.assertIn("source: ${UI_WEB_RUN_DIR}", web_block)
        self.assertIn("target: ${UI_WEB_RUN_DIR}", web_block)
        self.assertIn("create_host_path: false", web_block)
        self.assertNotIn("ports:", web_block)
        self.assertNotIn("expose:", web_block)
        self.assertNotIn("networks:", compose_contract)

        self.assertIn(
            'OCSERV_UI_WEB_SOCKET="${OCSERV_UI_WEB_RUN_DIR}/web.sock"',
            remote_common,
        )
        self.assertIn('UI_WEB_SOCKET="${OCSERV_UI_WEB_SOCKET}"', installer)
        self.assertIn("d %s 0700 10001 10001 -", installer)
        self.assertIn('UI_PORT="8765"', installer)
        self.assertIn(
            'UI_LOCAL_HOST="ocserv-$(openssl rand -hex 16).localhost"',
            installer,
        )
        self.assertIn(
            '[[ "${UI_LOCAL_HOST}" =~ ^ocserv-[0-9a-f]{32}\\.localhost$ ]]',
            installer,
        )
        self.assertIn("OCSERV_UI_LOCAL_HOST=${UI_LOCAL_HOST}", installer)
        self.assertIn("OCSERV_UI_LOCAL_PORT=${UI_PORT}", installer)
        self.assertIn("OCSERV_UI_VPN_DOMAIN=${DOMAIN}", installer)
        self.assertIn('OCSERV_UI_VPN_DOMAIN: "${DOMAIN}"', web_block)
        self.assertEqual(
            installer.count("url=http://${UI_LOCAL_HOST}:${UI_PORT}"), 1
        )
        self.assertIn(
            "tunnel_template=ssh -N -L "
            "127.0.0.1:${UI_PORT}:${UI_WEB_SOCKET} root@<vps-host>",
            installer,
        )
        self.assertNotIn("127.0.0.1:8080", installer)
        self.assertNotIn("url=http://localhost:", installer)

        base_compose = remote_common.split(
            'cat > "${OCSERV_COMPOSE_FILE}" <<\'EOF\'\n', 1
        )[1].split('\nEOF\n  chmod 0640 "${OCSERV_COMPOSE_FILE}"', 1)[0]
        self.assertIn("- ./logs:/var/log/ocserv:rw", base_compose)
        self.assertNotIn("docker.sock", base_compose)

    def test_vpn_journal_is_normalized_and_docker_socket_free(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        common = (
            repository / "skills" / "ocserv-vps" / "scripts" / "remote" / "common.sh"
        ).read_text(encoding="utf-8")
        control = (repository / "ui" / "control" / "service.go").read_text(encoding="utf-8")
        web = (repository / "ui" / "web" / "server.go").read_text(encoding="utf-8")

        self.assertIn("connect-script = /etc/ocserv/session-journal.sh", common)
        self.assertIn("disconnect-script = /etc/ocserv/session-journal.sh", common)
        self.assertIn("vpn-events.jsonl", common)
        self.assertIn("render_vpn_journal_assets", common)
        self.assertNotIn("docker.sock", common)
        self.assertIn('"list_connections"', control)
        self.assertIn('"disconnect_connection"', control)
        self.assertIn('"list_journal"', control)
        self.assertIn('s.runOCCTL("disconnect", "id", strconv.Itoa(id))', control)
        self.assertIn('path == "/api/v1/journal"', web)
        self.assertIn('path == "/api/v1/connections"', web)
        self.assertIn("os.OpenFile(s.config.RestartTrigger", control)
        self.assertNotIn('runOCCTL("stop", "now")', control)
        self.assertIn("install_ocserv_restart_bridge()", common)
        self.assertIn("PathExists=${OCSERV_UI_RESTART_TRIGGER}", common)
        self.assertIn("ExecStart=${docker_bin} restart --timeout 10 ${OCSERV_CONTAINER}", common)

    def test_ui_upgrade_is_transactional_and_preserves_access(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        controller = (repository / "skills" / "ocserv-vps" / "scripts" / "upgrade-ui.sh").read_text(encoding="utf-8")
        remote = (repository / "skills" / "ocserv-vps" / "scripts" / "remote" / "upgrade-ui.sh").read_text(encoding="utf-8")
        self.assertIn("--approve-restart", controller)
        self.assertIn("create_stack_backup", remote)
        self.assertIn("restore_previous", remote)
        self.assertIn("ensure_vpn_journal_config", remote)
        self.assertIn("render_compose_file", remote)
        self.assertIn("OCSERV_UI_LOCAL_HOST=${UI_LOCAL_HOST}", remote)
        self.assertIn("OCSERV_UI_VPN_DOMAIN=${DOMAIN}", remote)
        self.assertIn("install_ocserv_restart_bridge", remote)
        self.assertIn("print_ui_access_info_if_installed", remote)
        self.assertNotIn("docker.sock", remote)

    def test_installer_reserves_and_validates_host_identity_transactionally(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        remote_installer = (
            repository
            / "skills"
            / "ocserv-vps"
            / "scripts"
            / "remote"
            / "install-ui.sh"
        ).read_text(encoding="utf-8")
        remote_common = (
            repository
            / "skills"
            / "ocserv-vps"
            / "scripts"
            / "remote"
            / "common.sh"
        ).read_text(encoding="utf-8")
        remote_status = (
            repository
            / "skills"
            / "ocserv-vps"
            / "scripts"
            / "remote"
            / "ui-status.sh"
        ).read_text(encoding="utf-8")

        for contract in (
            'OCSERV_UI_HOST_USER="ocserv-ui-host"',
            'OCSERV_UI_HOST_GROUP="ocserv-ui-host"',
            'OCSERV_UI_HOST_UID="10001"',
            'OCSERV_UI_HOST_GID="10001"',
            'OCSERV_UI_HOST_HOME="/nonexistent"',
            'OCSERV_UI_HOST_SHELL="/usr/sbin/nologin"',
            "ui_host_identity_is_absent()",
            "ui_host_identity_is_exact()",
        ):
            self.assertIn(contract, remote_common)

        self.assertIn("ui_host_identity_is_absent", remote_installer)
        self.assertIn("Refusing host identity collision", remote_installer)
        self.assertIn("groupadd --system --gid", remote_installer)
        self.assertIn("useradd --system", remote_installer)
        self.assertIn('passwd --lock "${OCSERV_UI_HOST_USER}"', remote_installer)
        self.assertIn("ui_host_identity_is_exact", remote_installer)
        self.assertIn('userdel "${OCSERV_UI_HOST_USER}"', remote_installer)
        self.assertIn('groupdel "${OCSERV_UI_HOST_GROUP}"', remote_installer)
        self.assertIn('[[ "${HOST_UI_USER_CREATED}" == "1" ]]', remote_installer)
        self.assertIn('"${HOST_UI_GROUP_CREATED}" == "1"', remote_installer)
        self.assertIn("compose down --volumes", remote_installer)
        self.assertLess(
            remote_installer.index(
                'rm -rf -- "${UI_DATA_DIR}" "${UI_SECRETS_DIR}" "${UI_PUBLIC_DIR}"'
            ),
            remote_installer.index('userdel "${OCSERV_UI_HOST_USER}"'),
        )
        self.assertLess(
            remote_installer.index('userdel "${OCSERV_UI_HOST_USER}"'),
            remote_installer.index('groupdel "${OCSERV_UI_HOST_GROUP}"'),
        )
        self.assertIn("ui_host_identity_is_exact", remote_status)

    def test_ui_has_no_tcp_nginx_or_firewall_path(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        remote_installer = (
            repository
            / "skills"
            / "ocserv-vps"
            / "scripts"
            / "remote"
            / "install-ui.sh"
        ).read_text(encoding="utf-8")
        controller_installer = (
            repository
            / "skills"
            / "ocserv-vps"
            / "scripts"
            / "install-ui.sh"
        ).read_text(encoding="utf-8")

        for installer in (remote_installer, controller_installer):
            self.assertNotIn("--approve-firewall", installer)
            self.assertNotIn("APPROVE_FIREWALL", installer)
        for forbidden in (
            'cat > "${UI_NGINX_SITE}"',
            "proxy_pass",
            "listen ${UI_PORT}",
            "nginx -t",
            "systemctl reload nginx",
            'cat > "${UI_FIREWALL_SCRIPT}"',
            "iptables -w",
            "systemctl enable --now ocserv-vps-ui-firewall",
        ):
            self.assertNotIn(forbidden, remote_installer)

        web_server = (
            repository / "ui" / "web" / "main.go"
        ).read_text(encoding="utf-8")
        web_dockerfile = (
            repository / "ui" / "web" / "Dockerfile"
        ).read_text(encoding="utf-8")
        control_dockerfile = (
            repository / "ui" / "control" / "Dockerfile"
        ).read_text(encoding="utf-8")
        self.assertIn("os.Chmod(path, 0o600)", web_server)
        self.assertIn("info.Mode().Perm() != 0o700", web_server)
        self.assertIn("listener.SetUnlinkOnClose(false)", web_server)
        self.assertNotIn("OCSERV_UI_NGINX_GID", web_server)
        self.assertNotIn("EXPOSE", web_dockerfile)
        self.assertIn("FROM scratch", web_dockerfile)
        self.assertIn(
            "golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2",
            web_dockerfile,
        )
        self.assertIn('ENTRYPOINT ["/usr/local/bin/ocserv-ui"]', web_dockerfile)
        self.assertIn("go build -trimpath", control_dockerfile)
        self.assertIn(
            "golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2",
            control_dockerfile,
        )
        self.assertIn(
            'ENTRYPOINT ["/usr/local/bin/ocserv-control"]', control_dockerfile
        )
        self.assertIn(
            'CMD ["/usr/local/bin/ocserv-control", "healthcheck"]',
            control_dockerfile,
        )
        self.assertIn("FROM scratch", control_dockerfile)
        self.assertIn("FROM ${OCSERV_IMAGE} AS ocserv-tools", control_dockerfile)
        self.assertIn("ldd /usr/local/bin/occtl", control_dockerfile)
        self.assertIn("ldd /usr/local/bin/ocpasswd", control_dockerfile)
        self.assertNotIn("python", control_dockerfile.lower())
        self.assertFalse((repository / "ui" / "control" / "control.py").exists())

    def test_installer_creates_root_only_access_info_command(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        common = (
            repository / "skills" / "ocserv-vps" / "scripts" / "remote" / "common.sh"
        ).read_text(encoding="utf-8")
        installer = (
            repository / "skills" / "ocserv-vps" / "scripts" / "remote" / "install-ui.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('OCSERV_UI_ACCESS_INFO_SCRIPT="/usr/local/sbin/ocserv-ui-access-info"', common)
        self.assertIn("render_ui_access_info_script()", common)
        self.assertIn('[[ "${EUID}" -eq 0 ]]', common)
        self.assertIn("chmod 0700", common)
        self.assertIn("Access secret:", common)
        self.assertIn("ssh -p %s -N -T -L localhost:%s:%s root@%s", common)
        self.assertIn("OCSERV_UI_SSH_PORT=${SSH_PORT}", installer)
        self.assertIn("render_ui_access_info_script", installer)
        self.assertIn("print_ui_access_info_if_installed", common)
        self.assertIn("print_ui_access_info_if_installed", installer)
        self.assertIn('rm -f "${OCSERV_UI_ACCESS_INFO_SCRIPT}"', installer)

    def test_controller_tunnel_helpers_use_exact_installed_url(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        shell_helper = (
            repository / "skills" / "ocserv-vps" / "scripts" / "ui-tunnel.sh"
        ).read_text(encoding="utf-8")
        powershell_helper = (
            repository / "skills" / "ocserv-vps" / "scripts" / "ui-tunnel.ps1"
        ).read_text(encoding="utf-8")

        self.assertIn('REMOTE_SOCKET="/run/ocserv-ui-web/web.sock"', shell_helper)
        self.assertIn("/opt/ocserv-vps/ui.env", shell_helper)
        self.assertIn(
            '-L "localhost:${LOCAL_PORT}:${REMOTE_SOCKET}"', shell_helper
        )
        self.assertIn("ExitOnForwardFailure=yes", shell_helper)
        self.assertIn(
            "http://%s:%s/\\n' \"${BROWSER_HOST}\" \"${LOCAL_PORT}\"",
            shell_helper,
        )
        self.assertIn("$remoteSocket = '/run/ocserv-ui-web/web.sock'", powershell_helper)
        self.assertIn("/opt/ocserv-vps/ui.env", powershell_helper)
        self.assertIn(
            "'-L' \"localhost:${LocalPort}:${remoteSocket}\"", powershell_helper
        )
        self.assertIn("ExitOnForwardFailure=yes", powershell_helper)
        self.assertIn(
            "http://${browserHost}:${LocalPort}/", powershell_helper
        )
        for helper in (shell_helper, powershell_helper):
            self.assertNotIn("http://localhost:", helper)
            self.assertNotIn("0.0.0.0", helper)
            self.assertNotIn("GatewayPorts=yes", helper)
            self.assertIn("OCSERV_UI_LOCAL_(HOST|PORT)", helper)
            self.assertIn("ocserv-[0-9a-f]{32}", helper)

        ssh_library = (
            repository / "skills" / "ocserv-vps" / "scripts" / "lib" / "ssh.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("ocserv_validate_ssh_target", ssh_library)
        self.assertIn('"${ssh_args[@]}" -- "${host}"', ssh_library)

    @unittest.skipUnless(os.name == "posix", "strict file modes require POSIX")
    def test_cli_probe_strictly_converts_secure_cookies_to_root_only_header(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[3]
        installer = (
            repository
            / "skills"
            / "ocserv-vps"
            / "scripts"
            / "remote"
            / "install-ui.sh"
        ).read_text(encoding="utf-8")
        parser = self._installer_cookie_parser(installer)
        session_value = "B" * 64
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            session_headers = root / "session.headers"
            cookie_header = root / "cookie.header"
            session_headers.write_text(
                "HTTP/1.1 200 OK\r\n"
                f"Set-Cookie: __Host-ocserv_ui_session={session_value}; "
                "HttpOnly; Max-Age=43200; Path=/; SameSite=strict; Secure\r\n\r\n",
                encoding="ascii",
            )
            cookie_header.touch(mode=0o600)
            cookie_header.chmod(0o600)
            result = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    parser,
                    str(session_headers),
                    str(cookie_header),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                cookie_header.read_text(encoding="ascii"),
                f"Cookie: __Host-ocserv_ui_session={session_value}\n",
            )

            session_headers.write_text(
                "HTTP/1.1 200 OK\r\n"
                f"Set-Cookie: __Host-ocserv_ui_session={session_value}; "
                "HttpOnly; Max-Age=43200; Path=/; SameSite=strict\r\n\r\n",
                encoding="ascii",
            )
            rejected = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    parser,
                    str(session_headers),
                    str(cookie_header),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertNotIn(session_value, rejected.stderr)


if __name__ == "__main__":
    unittest.main()
