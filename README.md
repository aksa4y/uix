
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./media/3x-ui-dark.png">
    <img alt="3x-ui" src="./media/3x-ui-light.png">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/aksa4y/ui/releases"><img src="https://img.shields.io/github/v/release/aksa4y/3x-ui" alt="Release"></a>
  <a href="https://github.com/aksa4y/ui/actions"><img src="https://img.shields.io/github/actions/workflow/status/aksa4y/3x-ui/release.yml.svg" alt="Build"></a>
  <a href="#"><img src="https://img.shields.io/github/go-mod/go-version/aksa4y/3x-ui.svg" alt="GO Version"></a>
  <a href="https://github.com/aksa4y/ui/releases/latest"><img src="https://img.shields.io/github/downloads/aksa4y/3x-ui/total.svg" alt="Downloads"></a>
  <a href="https://www.gnu.org/licenses/gpl-3.0.en.html"><img src="https://img.shields.io/badge/license-GPL%20V3-blue.svg?longCache=true" alt="License"></a>
  <a href="https://pkg.go.dev/github.com/aksa4y/ui/v3"><img src="https://pkg.go.dev/badge/github.com/aksa4y/ui/v3.svg" alt="Go Reference"></a>
</p>

**3X-UI** — продвинутая веб-панель управления с открытым исходным кодом для управления серверами [Xray-core](https://github.com/XTLS/Xray-core). Она предоставляет аккуратный многоязычный интерфейс для развёртывания, настройки и мониторинга широкого спектра протоколов прокси и VPN — от одного VPS до развёртываний с несколькими узлами.

Созданный как улучшенный форк оригинального проекта X-UI, 3X-UI добавляет более широкую поддержку протоколов, повышенную стабильность, учёт трафика по каждому клиенту и множество функций для удобства использования.

> [!IMPORTANT]
> Этот проект предназначен только для личного использования. Пожалуйста, не используйте его в незаконных целях или в производственной среде.

## Возможности

- **Многопротокольные входящие подключения** — VLESS, VMess, Trojan, Shadowsocks, WireGuard, Hysteria2, HTTP, SOCKS (Mixed), Dokodemo-door / Tunnel и TUN.
- **Современные транспорты и безопасность** — TCP (Raw), mKCP, WebSocket, gRPC, HTTPUpgrade и XHTTP, защищённые с помощью TLS, XTLS и REALITY.
- **Fallback** — обслуживание нескольких протоколов на одном порту (например, VLESS и Trojan на 443) с помощью функции fallback в Xray.
- **Управление по каждому клиенту** — квоты трафика, даты истечения, лимиты IP, статус «онлайн» в реальном времени, а также ссылки для общего доступа, QR-коды и подписки в один клик.
- **Статистика трафика** — по каждому входящему, по каждому клиенту и по каждому исходящему, с возможностью сброса.
- **Поддержка нескольких узлов** — управление и масштабирование на несколько серверов из одной панели.
- **Исходящие подключения и маршрутизация** — WARP, NordVPN, пользовательские правила маршрутизации, балансировщики нагрузки и цепочки исходящих прокси.
- **Встроенный сервер подписок** с несколькими форматами вывода и [пользовательскими шаблонами страниц](docs/custom-subscription-templates.md).
- **Telegram-бот** для удалённого мониторинга и управления.
- **RESTful API** с документацией Swagger внутри панели.
- **Гибкое хранилище** — SQLite (по умолчанию) или PostgreSQL.
- **13 языков интерфейса** с тёмной и светлой темами.
- **Интеграция с Fail2ban** для применения лимитов IP по каждому клиенту.

## Скриншоты

<details>
<summary>Нажмите, чтобы развернуть</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./media/01-overview-dark.png">
  <img alt="Overview" src="./media/01-overview-light.png">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./media/02-add-inbound-dark.png">
  <img alt="Inbounds" src="./media/02-add-inbound-light.png">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./media/03-add-client-dark.png">
  <img alt="Add client" src="./media/03-add-client-light.png">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./media/05-add-nodes-dark.png">
  <img alt="Configs" src="./media/05-add-nodes-light.png">
</picture>

</details>

## Быстрый старт

```bash
bash <(curl -Ls https://raw.githubusercontent.com/aksa4y/uix/master/install.sh)
```



Во время установки генерируются случайные имя пользователя, пароль и путь доступа. После установки выполните `x-ui`, чтобы открыть меню управления, где можно запускать/останавливать сервис, просматривать или сбрасывать учётные данные для входа, управлять SSL-сертификатами и многое другое.



## Поддерживаемые платформы

**Операционные системы:** Ubuntu, Debian, Armbian, Fedora, CentOS, RHEL, AlmaLinux, Rocky Linux, Oracle Linux, Amazon Linux, Virtuozzo, Arch, Manjaro, Parch, openSUSE (Tumbleweed / Leap), Alpine и Windows.

**Архитектуры:** `amd64` · `386` · `arm64` (aarch64) · `armv7` · `armv6` · `armv5` · `s390x`.

## Варианты базы данных

3X-UI поддерживает два бэкенда, выбираемых при установке:

- **SQLite** (по умолчанию) — единый файл по пути `/etc/x-ui/x-ui.db`. Без настройки, идеально для небольших и средних развёртываний.
- **PostgreSQL** — рекомендуется при большом числе клиентов или конфигурациях с несколькими узлами. Установщик может установить PostgreSQL локально за вас или принять DSN к существующему серверу.

Во время выполнения бэкенд выбирается через переменные окружения (установщик записывает их за вас в `/etc/default/x-ui`):

```
XUI_DB_TYPE=postgres
XUI_DB_DSN=postgres://xui:password@127.0.0.1:5432/xui?sslmode=disable
```

### Перенос существующей установки SQLite в PostgreSQL

```bash
x-ui migrate-db --dsn "postgres://xui:password@127.0.0.1:5432/xui?sslmode=disable"
# затем задайте XUI_DB_TYPE и XUI_DB_DSN в /etc/default/x-ui и перезапустите:
systemctl restart x-ui
```

Исходный файл SQLite остаётся нетронутым; удалите его вручную после проверки нового бэкенда.

### Docker

Команда по умолчанию `docker compose up -d` продолжает использовать SQLite. Чтобы запустить со встроенным сервисом PostgreSQL, раскомментируйте две строки переменных окружения `XUI_DB_*` в `docker-compose.yml` и запустите с профилем:

```bash
docker compose --profile postgres up -d
```

Образ включает Fail2ban (включён по умолчанию) для применения **лимитов IP** по каждому клиенту. Fail2ban блокирует нарушителей с помощью `iptables`, что требует возможности `NET_ADMIN`. `docker-compose.yml` уже предоставляет её через `cap_add`; если вы вместо этого запускаете контейнер через `docker run`, добавьте возможности самостоятельно, иначе блокировки будут регистрироваться, но никогда не применяться:

```bash
docker run -d --cap-add=NET_ADMIN --cap-add=NET_RAW ... ghcr.io/aksa4y/ui
```

## Переменные окружения

| Переменная | Описание | По умолчанию |
| --- | --- | --- |
| `XUI_DB_TYPE` | Бэкенд базы данных: `sqlite` или `postgres` | `sqlite` |
| `XUI_DB_DSN` | Строка подключения PostgreSQL (когда `XUI_DB_TYPE=postgres`) | — |
| `XUI_DB_FOLDER` | Каталог для файла базы данных SQLite | `/etc/x-ui` |
| `XUI_DB_MAX_OPEN_CONNS` | Максимум открытых соединений (пул PostgreSQL) | — |
| `XUI_DB_MAX_IDLE_CONNS` | Максимум простаивающих соединений (пул PostgreSQL) | — |
| `XUI_INIT_WEB_BASE_PATH` | Начальный URI-путь для веб-панели | `/` |
| `XUI_ENABLE_FAIL2BAN` | Включить применение лимитов IP на основе Fail2ban | `true` |
| `XUI_LOG_LEVEL` | Уровень логирования (`debug`, `info`, `warning`, `error`) | `info` |
| `XUI_DEBUG` | Включить режим отладки | `false` |
| `XUI_TUNNEL_HEALTH_MONITOR` | Включить монитор состояния туннеля (опрашивает URL и перезапускает xray после многократных сбоев; перезапуск отключает всех клиентов) | `false` |
| `XUI_TUNNEL_HEALTH_PROXY` | Прокси, через который отправляется проба; укажите локальный входящий xray, чтобы проба проверяла туннель (например, `socks5://127.0.0.1:1080`). Пустое значение означает, что проба проверяет только связь с хостом | — |
| `XUI_TUNNEL_HEALTH_URL` | URL, опрашиваемый для проверки состояния туннеля | `https://www.cloudflare.com/cdn-cgi/trace` |
| `XUI_TUNNEL_HEALTH_INTERVAL` | Интервал между пробами | `30s` |
| `XUI_TUNNEL_HEALTH_TIMEOUT` | Таймаут на одну пробу | `10s` |
| `XUI_TUNNEL_HEALTH_FAILURES` | Число последовательных сбоев до запуска перезапуска | `3` |
| `XUI_TUNNEL_HEALTH_COOLDOWN` | Минимальная задержка между последовательными перезапусками | `5m` |





## Участие в разработке

Вклад приветствуется. 

## Поддержка проекта

**Если этот проект полезен для вас, вы можете поставить ему**:star2:


## Звезды с течением времени

 
