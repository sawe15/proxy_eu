# Hardening VM + запуск MTProxy для Telegram

В репозитории есть 3 скрипта:

- `harden_vm.sh` — базовый харденинг Linux VM (Debian/Ubuntu).
- `setup_mtproxy.sh` — установка и запуск MTProxy (на базе `mtg`) как `systemd` сервиса.
- `setup_mtproxy_docker.sh` — запуск MTProxy в Docker (проще в сопровождении и обновлениях).

## 1) Подготовка VM (рекомендуется первым шагом)

```bash
sudo bash harden_vm.sh
```

Что делает скрипт:

- Обновляет пакеты и ставит `ufw`, `fail2ban`, `unattended-upgrades`.
- Усиливает SSH конфиг:
  - `PermitRootLogin no`
  - `PasswordAuthentication no`
  - `KbdInteractiveAuthentication no`
  - `X11Forwarding no`
  - `MaxAuthTries 3`
  - `AllowTcpForwarding no`
- Включает `fail2ban` для SSH.
- Включает автоматические security-обновления.
- Применяет сетевые `sysctl` параметры безопасности.
- Включает firewall (`ufw`) c политикой `deny incoming`.

### Настраиваемые переменные

- `SSH_PORT` (по умолчанию `22`)
- `ALLOW_MTPROXY_PORTS` (по умолчанию `443 8888`)

Пример:

```bash
sudo SSH_PORT=2222 ALLOW_MTPROXY_PORTS="443" bash harden_vm.sh
```

## 2) Установка и запуск MTProxy

```bash
sudo bash setup_mtproxy.sh
```

Что делает скрипт:

- Создаёт системного пользователя `mtproxy`.
- Скачивает `mtg` из конкретного тега релиза `MTG_VERSION` (без использования `releases/latest`) и пытается найти корректный asset автоматически; при необходимости можно задать прямой `MTG_DOWNLOAD_URL`.
- Генерирует секрет в `/etc/mtproxy-secret`.
- Создаёт `systemd`-юнит `/etc/systemd/system/mtproxy.service`.
- Запускает сервис и включает автозапуск.
- Печатает готовую ссылку подключения `tg://proxy?...`.

### Настраиваемые переменные

- `MTPROXY_PORT` (по умолчанию `443`)
- `MTPROXY_BIND_IP` (по умолчанию `0.0.0.0`)
- `MTPROXY_DOMAIN` (по умолчанию `www.cloudflare.com`)
- `MTPROXY_AD_TAG` (опционально)
- `MTG_VERSION` (по умолчанию `v2.1.13`, рекомендуется пиновать)
- `MTG_DOWNLOAD_URL` (опционально, прямой URL asset для полного ручного контроля загрузки)

Пример:

```bash
sudo MTPROXY_PORT=443 MTPROXY_DOMAIN=azure.microsoft.com MTG_VERSION=v2.1.13 bash setup_mtproxy.sh
```


## 3) Альтернатива: запуск MTProxy в Docker

Если хотите более простой lifecycle (обновление образа, изоляция, минимум ручной установки бинарей), используйте Docker-вариант:

```bash
sudo bash setup_mtproxy_docker.sh
```

Что делает скрипт:

- Устанавливает `docker.io` (если не установлен) и запускает Docker daemon.
- Генерирует секрет через официальный образ `nineseconds/mtg:<tag>` (`generate-secret --hex`).
- Создаёт конфиг в TOML (`/etc/mtg.toml`).
- Запускает контейнер `mtg-proxy` с `--restart unless-stopped` и публикует порт наружу.

### Переменные Docker-скрипта

- `MTPROXY_PORT` (внешний порт, по умолчанию `443`)
- `MTPROXY_INTERNAL_PORT` (порт внутри контейнера, по умолчанию `3128`)
- `MTPROXY_DOMAIN` (домен для генерации секрета, по умолчанию `www.cloudflare.com`)
- `MTPROXY_SECRET` (опционально, если хотите задать вручную)
- `MTG_DOCKER_TAG` (по умолчанию `2`, рекомендуется пиновать)
- `DOCKER_IMAGE` (по умолчанию `nineseconds/mtg:${MTG_DOCKER_TAG}`)
- `MTG_CONFIG_PATH` (по умолчанию `/etc/mtg.toml`)

Пример:

```bash
sudo MTPROXY_PORT=443 MTG_DOCKER_TAG=2 MTPROXY_DOMAIN=digitalocean.com bash setup_mtproxy_docker.sh
```

## 4) Проверка

```bash
sudo systemctl status mtproxy --no-pager
sudo journalctl -u mtproxy -n 100 --no-pager
sudo ss -tulpen | rg ':443|:8888'
sudo ufw status verbose
```

## 5) Важные рекомендации

- Перед отключением password auth убедитесь, что вход по SSH-ключу работает.
- Храните секрет MTProxy в тайне (`/etc/mtproxy-secret`).
- Периодически обновляйте систему и пересматривайте правила firewall.
