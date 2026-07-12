[English](README.md) | [Русский](README_RU.md)

# Dockerized ocserv для VPS

Полная установка и эксплуатация ocserv VPN на чистом VPS с Debian или Ubuntu. GitHub Actions собирает явный [`docker/Dockerfile`](docker/Dockerfile) из закреплённого исходного релиза после проверки SHA-256 и GPG и публикует его в `ghcr.io/khorevaa/ocserv-vps`. Skill разворачивает только точный GHCR manifest digest, а затем настраивает сертификат, пользователей, forwarding, NAT, firewall, health checks, обновление и rollback.

Канонический устанавливаемый bundle находится в [`skills/ocserv-vps/`](skills/ocserv-vps/).

## Возможности

- read-only проверка чистого или уже управляемого VPS
- сохранение существующей установки Docker и установка Docker только при его отсутствии
- установка только Compose v2 plugin, если Docker уже есть, а Compose отсутствует
- обязательный digest базового образа вместо `latest`
- публикация immutable version-plus-source-SHA tags в GitHub Container Registry
- загрузка на VPS только ссылок `ghcr.io/...@sha256:`
- получение сертификата Let's Encrypt
- создание конфигурации ocserv и первого password-пользователя
- IPv4 forwarding, ограничивающий ingress firewall, VPN forwarding и NAT
- запуск ocserv через host networking с `/dev/net/tun`, `NET_ADMIN` и `NET_RAW`
- проверка image ID, конфигурации и TCP/UDP listeners
- добавление пользователей со сгенерированными паролями, обновление образа и rollback
- опциональная подготовка nginx на порту 80 для ACME и будущего UI без проксирования ocserv

Bootstrap меняет firewall и при ошибочном SSH-порте может оборвать доступ. Сохраняйте независимую SSH-сессию и сначала проверяйте dry-run.

## Требования

- root SSH-доступ к Debian или Ubuntu
- `/dev/net/tun`
- публичный IPv4 и домен, направленный на VPS
- image, опубликованный repository workflow из точного source tuple и закреплённого base image
- публичный или заранее авторизованный доступ к `ghcr.io/...@sha256:<digest>`
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
- [`bootstrap-vps.sh`](skills/ocserv-vps/scripts/bootstrap-vps.sh): полная установка чистого VPS
- [`preflight.sh`](skills/ocserv-vps/scripts/preflight.sh): read-only проверка хоста и stack
- [`deploy-release.sh`](skills/ocserv-vps/scripts/deploy-release.sh): pull и активация нового verified GHCR digest
- [`rollback-release.sh`](skills/ocserv-vps/scripts/rollback-release.sh): переход на сохранённый image с автоматическим восстановлением
- [`status.sh`](skills/ocserv-vps/scripts/status.sh): container, certificate, listeners, network и backups
- [`add-user.sh`](skills/ocserv-vps/scripts/add-user.sh): создание password-пользователя

Полная процедура и safety gates находятся в [`skills/ocserv-vps/SKILL.md`](skills/ocserv-vps/SKILL.md).

## nginx

Nginx — опциональная подготовка под будущий UI. Флаг `--prepare-nginx` создаёт только ACME webroot site на порту 80. Ocserv продолжает напрямую занимать TCP и UDP VPN-порт; nginx не завершает TLS и не проксирует VPN-протокол.

## Публикация image

Запустите workflow `Publish ocserv image` вручную с точной версией, source URL, SHA-256, detached signature, signing key/fingerprint и digest базового образа. Для bootstrap или upgrade используйте полный manifest digest из workflow summary. Для pull с чистого VPS без авторизации GHCR package должен быть публичным.

## Лицензия

MIT. См. [LICENSE](LICENSE).

Автоматизация репозитория распространяется по MIT. Публикуемые container images содержат ocserv и соответствующее дерево исходников на условиях upstream GPLv2-or-later.
