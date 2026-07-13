[English](README.md) | [Русский](README_RU.md)

# Codex-skill для ocserv-vps

В этом репозитории находится устанавливаемый Codex-skill для развёртывания и эксплуатации Dockerized ocserv VPN и приватной панели управления через SSH-туннель на VPS с Debian или Ubuntu.

Продуктовый код, сборки контейнеров, исходники UI, самостоятельный установщик и workflows публикации в GHCR перенесены в [`khorevaa/ocserv-vps`](https://github.com/khorevaa/ocserv-vps). Здесь остаются только инструкции Codex, клиентская автоматизация и серверные сценарии, которые skill передаёт по SSH.

## Установка skill

```text
$skill-installer install https://github.com/khorevaa/ocserv-vps-skil/tree/develop/skills/ocserv-vps
```

Явный вызов:

```text
$ocserv-vps разверни полностью настроенный Dockerized ocserv VPN на моём VPS
```

## Что автоматизируется

- read-only preflight и проверка состояния VPS
- bootstrap с сохранением существующего Docker, ACME, forwarding, NAT и ограничивающим firewall
- развёртывание проверенных version-тегов из `ghcr.io/khorevaa/ocserv-vps`
- обязательный реальный вход OpenConnect и HTTPS-проверка через туннель
- управление VPN-пользователями со случайными паролями
- транзакционные обновление и rollback ocserv
- установка и обновление приватного Unix-socket UI, ротация access secret, status и helpers SSH-туннеля

Bootstrap меняет firewall и может прервать SSH/VPN-сессии. Сохраняйте независимую SSH-сессию, сначала проверяйте dry-run и явно подтверждайте изменения firewall/restart.

## Продуктовый репозиторий

В [`khorevaa/ocserv-vps`](https://github.com/khorevaa/ocserv-vps) находятся:

- `docker/` и проверяемая сборка образа ocserv
- `ui/web/` и `ui/control/`
- самостоятельный `install.sh` и серверный менеджер `ocserv-vps`
- workflows публикации GHCR и продуктовые релизы

Skill принимает UI-образы только с OCI source label `https://github.com/khorevaa/ocserv-vps`.

## Лицензия

MIT. См. [LICENSE](LICENSE).
