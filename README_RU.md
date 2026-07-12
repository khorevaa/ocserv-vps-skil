[English](README.md) | [Русский](README_RU.md)

# Skill для релизов ocserv на VPS

Безопасная миграция, обновление, проверка и откат существующей установки ocserv на VPS под управлением root с Debian или Ubuntu.

Skill сохраняет `/etc/ocserv`, сертификаты, данные аутентификации, маршрутизацию, правила firewall и sysctl. Он заменяет только релиз ocserv и управляемый systemd-unit, размещая версионные релизы в `/opt/ocserv`.

Канонический устанавливаемый bundle находится в [`skills/ocserv-vps/`](skills/ocserv-vps/).

## Модель безопасности

- точная версия релиза и HTTPS-ссылки на артефакты
- обязательные SHA-256, detached signature и полный fingerprint ключа подписи
- read-only preflight перед развёртыванием
- сборка от непривилегированного пользователя
- проверка конфигурации до переключения
- блокировка параллельных операций, root-only backup и атомарное переключение релиза
- проверка systemd-сервиса, запущенного бинарного файла и listener
- автоматическое восстановление предыдущего релиза или принятого под управление сервиса при ошибке активации

Развёртывание и откат перезапускают ocserv и отключают активные VPN-сессии. Skill вызывается только явно и требует флаг `--approve-restart`.

## Требования

Рабочая станция оператора:

- Bash
- OpenSSH client
- независимый SSH-доступ к VPS

Целевой VPS:

- Debian или Ubuntu с `apt` и systemd
- root-доступ
- существующая рабочая конфигурация ocserv, обычно `/etc/ocserv/ocserv.conf`
- достаточно места для сборки нового и хранения предыдущего релиза

Skill не создаёт новую VPN-конфигурацию или firewall policy с нуля.

## Установка в Codex

Используйте встроенный установщик skills:

```text
$skill-installer install https://github.com/khorevaa/ocserv-vps-skil/tree/develop/skills/ocserv-vps
```

После установки вызывайте skill явно:

```text
$ocserv-vps проверь существующий ocserv перед обновлением
```

## Сценарии

Bundle предоставляет четыре операторских сценария:

1. `preflight.sh` без изменений проверяет хост, конфигурацию, сервисы, listeners, сессии, свободное место и путь целевого релиза.
2. `deploy-release.sh` проверяет и собирает закреплённый релиз, сохраняет текущее состояние, переключает релизы и автоматически восстанавливает прежнее состояние при ошибке.
3. `status.sh` показывает managed service, активный бинарный файл, сохранённые релизы, listeners, состояние и backups.
4. `rollback-release.sh` проверяет и активирует сохранённый релиз, восстанавливая исходный релиз при неуспешном health check.

Полная инструкция находится в [`skills/ocserv-vps/SKILL.md`](skills/ocserv-vps/SKILL.md).

## Структура репозитория

- [`skills/ocserv-vps/SKILL.md`](skills/ocserv-vps/SKILL.md): канонические инструкции skill
- [`skills/ocserv-vps/scripts/`](skills/ocserv-vps/scripts/): локальные entrypoints и bundled remote implementations
- [`skills/ocserv-vps/references/`](skills/ocserv-vps/references/): sourcing релиза, транзакционная модель и troubleshooting
- [`skills/ocserv-vps/agents/openai.yaml`](skills/ocserv-vps/agents/openai.yaml): метаданные интерфейса Codex/OpenAI

## Лицензия

MIT. См. [LICENSE](LICENSE).
