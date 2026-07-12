[English](README.md) | [Русский](README_RU.md)

# Dockerized ocserv для VPS

Полная установка и эксплуатация ocserv VPN на чистом VPS с Debian или Ubuntu. GitHub Actions собирает явный [`docker/Dockerfile`](docker/Dockerfile) из закреплённого исходного релиза после проверки SHA-256 и GPG и публикует его в `ghcr.io/khorevaa/ocserv-vps`. Skill разворачивает version-tag `ghcr.io/khorevaa/ocserv-vps:<version>`, а затем настраивает сертификат, пользователей, forwarding, NAT, firewall, health checks, обновление и rollback.

Канонический устанавливаемый bundle находится в [`skills/ocserv-vps/`](skills/ocserv-vps/).

## Возможности

- read-only проверка чистого или уже управляемого VPS
- сохранение существующей установки Docker и установка Docker только при его отсутствии
- установка только Compose v2 plugin, если Docker уже есть, а Compose отсутствует
- обязательный digest базового образа вместо `latest`
- публикация version tags вида `ghcr.io/khorevaa/ocserv-vps:1.5.0` в GitHub Container Registry
- загрузка на VPS только явных version tags; `latest` не используется
- получение сертификата Let's Encrypt
- создание конфигурации ocserv и первого password-пользователя
- IPv4 forwarding, ограничивающий ingress firewall, VPN forwarding и NAT
- запуск ocserv через host networking с `/dev/net/tun`, `NET_ADMIN` и `NET_RAW`
- проверка image ID, конфигурации и TCP/UDP listeners
- обязательный реальный вход через OpenConnect и HTTPS-запрос через tunnel из изолированного network namespace после bootstrap, upgrade и rollback
- controller-side OpenConnect-тест для Linux или WSL2
- опциональная Dockerized-панель для обзора сервера, добавления пользователей и смены паролей
- добавление пользователей со сгенерированными паролями, обновление образа и rollback
- опциональная подготовка nginx на порту 80 только для ACME, вне VPN и UI path

Bootstrap меняет firewall и при ошибочном SSH-порте может оборвать доступ. Сохраняйте независимую SSH-сессию и сначала проверяйте dry-run.

## Требования

- root SSH-доступ к Debian или Ubuntu
- `/dev/net/tun`
- публичный IPv4 и домен, направленный на VPS
- image, опубликованный repository workflow из точного source tuple и закреплённого base image
- публичный или заранее авторизованный доступ к `ghcr.io/khorevaa/ocserv-vps:<version>`
- место для хранения минимум двух образов

## Установка в Codex

```text
$skill-installer install https://github.com/khorevaa/ocserv-vps-skil/tree/develop/skills/ocserv-vps
```

Явный вызов:

```text
$ocserv-vps разверни полностью настроенный Dockerized ocserv VPN на моём VPS
```

## Основные сценарии

- [Publish ocserv image](.github/workflows/publish-ocserv-image.yml): проверка source, сборка явного Dockerfile и push в GHCR
- [Publish ocserv UI images](.github/workflows/publish-ui-images.yml): тестирование и публикация согласованных web/control images в GHCR
- [`bootstrap-vps.sh`](skills/ocserv-vps/scripts/bootstrap-vps.sh): полная установка чистого VPS
- [`preflight.sh`](skills/ocserv-vps/scripts/preflight.sh): read-only проверка хоста и stack
- [`deploy-release.sh`](skills/ocserv-vps/scripts/deploy-release.sh): pull, активация и OpenConnect-проверка новой GHCR-версии
- [`rollback-release.sh`](skills/ocserv-vps/scripts/rollback-release.sh): переход на сохранённый image с автоматическим восстановлением
- [`status.sh`](skills/ocserv-vps/scripts/status.sh): container, certificate, listeners, network и backups
- [`add-user.sh`](skills/ocserv-vps/scripts/add-user.sh): создание password-пользователя
- [`test-openconnect-client.sh`](skills/ocserv-vps/scripts/test-openconnect-client.sh): локальная Linux/WSL-проверка tunnel и HTTPS data path
- [`install-ui.sh`](skills/ocserv-vps/scripts/install-ui.sh): транзакционная установка UI с Unix socket
- [`upgrade-ui.sh`](skills/ocserv-vps/scripts/upgrade-ui.sh): транзакционное обновление UI с сохранением URL, секрета и JSON-состояния
- [`ui-tunnel.sh`](skills/ocserv-vps/scripts/ui-tunnel.sh) / [`ui-tunnel.ps1`](skills/ocserv-vps/scripts/ui-tunnel.ps1): локальный SSH-туннель, который получает и показывает точный установленный random URL
- [`rotate-ui-access.sh`](skills/ocserv-vps/scripts/rotate-ui-access.sh): ротация секрета UI и отзыв операторских сессий
- [`ui-status.sh`](skills/ocserv-vps/scripts/ui-status.sh): состояние UI-контейнеров, приватного socket, tunnel contract и handoff

Полная процедура и safety gates находятся в [`skills/ocserv-vps/SKILL.md`](skills/ocserv-vps/SKILL.md).

## nginx

Nginx остаётся вне VPN и UI data path. Флаг `--prepare-nginx` создаёт только ACME webroot. Ocserv продолжает напрямую занимать TCP и UDP VPN-порт, а UI предоставляет на VPS только `/run/ocserv-ui-web/web.sock`.

Лишённый сети UI-контейнер не публикует Docker-порт и не использует ни
`127.0.0.1:8080`, ни внутреннюю Docker-сеть, ни nginx proxy.

UI не публикуется в Интернет и не добавляет TCP listener, nginx-конфигурацию,
firewall rule или service. Создайте туннель командой
`ssh -N -L 127.0.0.1:8765:/run/ocserv-ui-web/web.sock root@vpn.example.com` и
откройте точный `http://ocserv-<32hex>.localhost:8765/` из `ui.env` или
root-only handoff. Не заменяйте его на `http://localhost:8765/`. Комплектные
`ui-tunnel` helpers получают, проверяют и показывают установленный URL.

Установка резервирует host UID/GID `10001` за locked nologin account и group
`ocserv-ui-host`. Любая коллизия имени или числового ID прерывает транзакцию;
rollback удаляет только созданную им неизменённую identity.

MVP UI использует один отдельный секрет доступа. Панель показывает состояние сервера, активные подключения и нормализованный журнал подключений/отключений ocserv; позволяет завершать отдельную сессию, добавлять VPN-пользователей и менять сгенерированные пароли. Тема автоматически следует системной с ручным выбором светлого или тёмного режима. Секрет вводится в отдельной форме, не помещается в URL и сразу обменивается на непрозрачную серверную сессию оператора сроком не более 12 часов.

Оба сервиса UI собраны как Go-бинарники. Непривилегированный web-процесс
хранит только версионированный JSON, а изолированный control-sidecar сохраняет
фиксированный протокол Unix-сокета и вызывает `occtl`/`ocpasswd` без shell.
В контейнерах нет Python, SQLite или отдельного сервиса базы данных.

В root SSH-сессии команда `ocserv-ui-access-info` выводит точный локальный URL, текущий секрет и готовую команду SSH-туннеля. Её вывод является конфиденциальным.

## Публикация image

Запустите workflow `Publish ocserv image` вручную с точной версией, source URL, SHA-256, detached signature, signing key/fingerprint и digest базового образа. Для bootstrap или upgrade используйте version-tag из workflow summary. Для pull с чистого VPS без авторизации GHCR package должен быть публичным.

## Лицензия

MIT. См. [LICENSE](LICENSE).

Автоматизация репозитория распространяется по MIT. Публикуемые container images содержат ocserv и соответствующее дерево исходников на условиях upstream GPLv2-or-later.
