# morozovka-bridge — web UI

![CI](https://github.com/IvanBud123/morozovka-bridge/actions/workflows/ci.yml/badge.svg?branch=web-main)
![License](https://img.shields.io/github/license/IvanBud123/morozovka-bridge)
![Python](https://img.shields.io/badge/python-3.11+-blue)

Веб-интерфейс для управления пробросом сервисов из изолированной сети вуза
наружу через сервер с белым IP. Работает поверх OpenVPN, даёт удобный
дашборд, управление сервисами, разделение ролей и автоматическое
тестирование всей цепочки.

> Полная документация по базовому CLI-установщику — в `README.md` ветки `main`.
> Этот файл описывает **веб-морду** и всё, что с ней связано.

---

## Содержание

- [Что умеет](#что-умеет)
- [Архитектура](#архитектура)
- [Роли](#роли)
- [Установка](#установка)
- [Первый вход](#первый-вход)
- [Работа с сервисами](#работа-с-сервисами)
- [Тестирование цепочки](#тестирование-цепочки)
- [Пользователи](#пользователи)
- [Открытие морды наружу](#открытие-морды-наружу)
- [CLI-утилита](#cli-утилита)
- [Обновление](#обновление)
- [Удаление](#удаление)
- [Troubleshooting](#troubleshooting)
- [Структура проекта](#структура-проекта)
- [Безопасность](#безопасность)

---

## Что умеет

- 📊 **Дашборд** со статусами всех сервисов — 🟢 OK, 🔴 FAIL, ⚪ нет данных.
- 🔧 **CRUD сервисов** прямо из браузера — добавление, редактирование, удаление.
  При каждом изменении автоматически пересобирается `config.env` и запускается
  `scripts/add-service.sh`, чтобы применить конфигурацию на Малинке и внешнем сервере.
- 🧪 **Прогон тестов** всей цепочки (7 шагов) — как для одного сервиса, так и для
  всех сразу, параллельно. Результаты сохраняются в БД.
- 👥 **Пользователи и роли** — admin / operator / viewer, управление только
  своими сервисами для operator.
- 🔑 **Смена пароля** в личном кабинете.
- 📈 **История тестов** — последние 10 прогонов для каждого сервиса.
- 🚦 **Флаги проблем** — если тест упал, шаг подсвечивается красным с подсказкой,
  что именно проверить.

---

## Архитектура

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Интернет                                    │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │  Внешний сервер (белый IP)   │
              │  Nginx: reverse proxy + tcp  │
              │  OpenVPN server              │
              └──────────────┬───────────────┘
                             │  OpenVPN (tun0)
                             ▼
              ┌──────────────────────────────┐
              │  Raspberry Pi                │
              │  ├─ OpenVPN client           │
              │  ├─ socat-форвардеры         │
              │  └─ ★ morozovka-web (5000)   │  ← веб-морда
              └──────────────┬───────────────┘
                             │  Ethernet (192.168.50.0/24)
                             ▼
                   ┌─────────┴─────────┐
                   │                   │
            192.168.50.2        192.168.50.3
            Вузовский сервер 1  Вузовский сервер 2
```

Веб-морда **запускается на Малинке**, слушает `127.0.0.1:5000` и попадает
наружу через ту же самую схему, что и любой другой сервис — добавляется
строка в `SERVICES` и запускается `add-service.sh`.

---

## Роли

| Роль | Права |
|---|---|
| `viewer` | Просмотр сервисов и дашборда, запуск тестов. Не может менять. |
| `operator` | Всё, что viewer + создание/редактирование/удаление **своих** сервисов. |
| `admin` | Всё. Управление пользователями, все сервисы, смена ролей. |

Сервисы без владельца (`owner_id = NULL`) доступны на редактирование только `admin`.

---

## Установка

Требования: развёрнутая базовая установка `morozovka-bridge` из ветки `main`
(OpenVPN поднят, `config.env` заполнен, коммутатор и внутренние серверы
настроены).

```bash
cd ~/morozovka-bridge
git checkout web-main
git pull

sudo ./install-web.sh
```

Скрипт делает всё сам:

1. Ставит системные пакеты (`python3-venv`, `rsync`, `netcat-openbsd`, `openssl`).
2. Копирует проект в `/opt/morozovka-bridge`.
3. Генерирует `WEB_SECRET` и дописывает его в `config.env` (если ещё нет).
4. Создаёт виртуальное окружение и ставит Python-зависимости.
5. Инициализирует SQLite-базу и импортирует сервисы из `config.env`.
6. Ставит и запускает systemd-юнит `morozovka-web`.

Проверка:

```bash
sudo systemctl status morozovka-web --no-pager
curl -s http://127.0.0.1:5000/healthz
# → {"ok":true,"time":"..."}
```

---

## Первый вход

Создайте администратора:

```bash
cd /opt/morozovka-bridge
./web/.venv/bin/python -m web.manage create-admin admin
# Пароль: ********
# [+] Админ admin создан
```

Проверьте, что он есть:

```bash
./web/.venv/bin/python -m web.manage list-users
```

Чтобы открыть морду снаружи — см. [Открытие морды наружу](#открытие-морды-наружу).

---

## Работа с сервисами

### Формат сервиса

| Поле | Описание |
|---|---|
| `name` | Идентификатор (латиница, цифры, `_`, `-`). Используется в именах файлов и systemd. |
| `domain` | Домен для `http`, либо `_` если домена нет. Для `tcp` — всегда `_`. |
| `internal_ip` | IP сервера в вузе (`192.168.50.2`). |
| `internal_port` | Порт сервиса на внутреннем сервере. |
| `vpn_port` | Порт на Малинке, слушает `socat` на `PI_VPN_IP`. |
| `type` | `http` (reverse proxy) или `tcp` (stream). |
| `external_port` | Порт, открытый наружу на внешнем сервере. |
| `description` | Необязательное описание. |

### HTTP vs TCP

- **`http`** — Nginx как reverse proxy, разбирает `Host`, прокидывает
  `X-Real-IP`, `X-Forwarded-For`, `Upgrade` (WebSocket). Подходит для GitTea,
  Wiki, любых веб-приложений.
- **`tcp`** — Nginx stream. Пробрасывает байты как есть. Подходит для SSH,
  MySQL, Redis, любых бинарных протоколов.

### Добавить сервис

1. Дашборд → **Сервисы** → **Добавить**.
2. Заполнить поля, сохранить.
3. Веб-морда автоматически:
   - пересоберёт блок `SERVICES=( ... )` в `config.env`,
   - запустит `scripts/add-service.sh`,
   - создаст `socat@<имя>.service` на Малинке,
   - пропишет Nginx-конфиг на внешнем сервере,
   - сделает `systemctl reload nginx`.

### Удалить сервис

Карточка сервиса → **Удалить сервис**. Аналогично — конфиги удаляются на
Малинке и внешнем сервере.

> ⚠️ Если ты создал сервис раньше через CLI (`config.env` руками) и он уже
> импортирован в БД — веб-морда его увидит. Удаление через морду удалит его
> и из `config.env`, и с серверов.

---

## Тестирование цепочки

Для каждого сервиса прогоняется **7 шагов**:

| # | Шаг | Что проверяет |
|---|---|---|
| 1 | `tun0` | OpenVPN-туннель на Малинке поднят |
| 2 | `systemctl is-active socat@X` | socat-форвардер запущен |
| 3 | `ping internal_ip` | Внутренний сервер пингуется |
| 4 | `nc -zv internal_ip internal_port` | Порт на внутреннем сервере открыт |
| 5 | `ssh ext "nginx -t"` | Nginx на внешнем сервере валиден |
| 6 | `nc -zv external_host external_port` | Внешний порт открыт снаружи |
| 7 | `curl -w '%{http_code}'` (только http) | Сервис отдаёт код < 500 |

Результаты видны:

- На **дашборде** — флажок и время последнего теста.
- На **карточке сервиса** — подробный список шагов с длительностью каждого и
  подсказкой, что проверять при провале.

Кнопки:

- **Прогнать тест** (на карточке) — только для этого сервиса.
- **Проверить всё** (на дашборде) — параллельно для всех сервисов, через
  `asyncio.gather`.

---

## Пользователи

Управление доступно только `admin` (пункт **Пользователи** в шапке).

### Создать пользователя

Пользователи → **Добавить** → указать:
- логин,
- пароль (минимум 6 символов),
- роль,
- email (необязательно).

### Сменить роль / пароль / активность

Клик по **карандашу** напротив пользователя. Пустое поле «Пароль» —
пароль не меняется.

### Удалить

Корзина напротив пользователя. **Себя удалить нельзя** — защита от
«выстрела в ногу».

---

## Открытие морды наружу

Веб-морда слушает `127.0.0.1:5000`. Чтобы открыть её снаружи:

1. Добавьте сервис в `config.env`:

   ```bash
   "morozovka-web|_|127.0.0.1|5000|8090|http|8090"
   ```

2. Примените:

   ```bash
   cd ~/morozovka-bridge
   sudo ./scripts/add-service.sh
   ```

3. Откройте порт на внешнем сервере:

   ```bash
   ssh root@<EXTERNAL_HOST> "ufw allow 8090/tcp"
   ```

4. Откройте в браузере:

   ```
   http://<EXTERNAL_HOST>:8090/
   ```

### HTTPS вручную

Проект намеренно **не ставит Let's Encrypt** — предполагается, что сертификаты
вы ставите сами (self-signed или через свой CA). Чтобы поднять HTTPS на морде:

1. Сгенерируйте self-signed сертификат на внешнем сервере:

   ```bash
   sudo mkdir -p /etc/ssl/morozovka
   sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
       -keyout /etc/ssl/morozovka/web.key \
       -out    /etc/ssl/morozovka/web.crt \
       -subj "/CN=morozovka-web"
   ```

2. Откройте `/etc/nginx/sites-available/vuz-morozovka-web.conf` на внешнем сервере
   и замените блок `server { listen 8090; ... }` на:

   ```nginx
   server {
       listen 8090 ssl;
       server_name _;

       ssl_certificate     /etc/ssl/morozovka/web.crt;
       ssl_certificate_key /etc/ssl/morozovka/web.key;

       client_max_body_size 512M;

       location / {
           proxy_pass http://10.8.0.2:8090;
           proxy_http_version 1.1;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;
           proxy_read_timeout 300s;
       }
   }
   ```

3. `sudo nginx -t && sudo systemctl reload nginx`

---

## CLI-утилита

Все команды запускаются из `/opt/morozovka-bridge`:

```bash
cd /opt/morozovka-bridge
PY=./web/.venv/bin/python

# Инициализировать таблицы в БД (идемпотентно)
$PY -m web.manage init-db

# Импортировать SERVICES из config.env в БД (пропускает уже существующие)
$PY -m web.manage import

# Создать админа
$PY -m web.manage create-admin admin
$PY -m web.manage create-admin admin --password 'Секрет123' --email 'a@b.c'

# Сменить пароль пользователя
$PY -m web.manage set-password admin

# Списки
$PY -m web.manage list-users
$PY -m web.manage list-services
```

---

## Обновление

```bash
cd ~/morozovka-bridge
git pull

# Переустановить только веб-часть
sudo ./install-web.sh
```

`install-web.sh` идемпотентен:
- БД **не удаляется** (сохраняются пользователи и история тестов).
- Виртуальное окружение пересоздаётся, зависимости переставляются.
- Сервис перезапускается.

Если обновлялись зависимости из `requirements.txt`, они подтянутся
автоматически.

---

## Удаление

Удалить только веб-морду:

```bash
sudo systemctl disable --now morozovka-web
sudo rm /etc/systemd/system/morozovka-web.service
sudo rm -rf /opt/morozovka-bridge
```

Удалить полностью (включая OpenVPN, Nginx, socat):

```bash
cd ~/morozovka-bridge
sudo ./uninstall.sh
```

---

## Troubleshooting

### Служба не стартует

```bash
sudo systemctl status morozovka-web --no-pager
sudo journalctl -u morozovka-web -n 100 --no-pager
```

### `healthz` не отвечает

```bash
curl -v http://127.0.0.1:5000/healthz
ss -tlnp | grep 5000
```

### `ModuleNotFoundError: No module named 'web'`

Проверь `WorkingDirectory` в `/etc/systemd/system/morozovka-web.service` —
должно быть `/opt/morozovka-bridge`.

### `WEB_SECRET не задан`

Добавь в `config.env`:

```bash
WEB_SECRET=$(openssl rand -hex 32)
```

и перезапусти:

```bash
sudo systemctl restart morozovka-web
```

### `bcrypt` ругается (`AttributeError: module 'bcrypt' has no attribute '__about__'`)

Это старый баг `passlib`. В web-main ветке `passlib` **не используется** —
только `bcrypt` напрямую. Если видишь ошибку:

```bash
rm -rf /opt/morozovka-bridge/web/.venv
sudo ./install-web.sh
```

### Забыл пароль админа

```bash
cd /opt/morozovka-bridge
./web/.venv/bin/python -m web.manage set-password admin
```

### Тесты падают — что проверить

1. Открой карточку проблемного сервиса — там будет **красный шаг** с подсказкой.
2. Вручную на Малинке:
   ```bash
   ip link show tun0
   systemctl status socat@<имя>
   ping 192.168.50.2
   nc -zv 192.168.50.2 3000
   ```
3. На внешнем сервере:
   ```bash
   nginx -t
   ss -tlnp | grep <external_port>
   ```
4. Firewall на внешнем сервере:
   ```bash
   ufw status | grep <external_port>
   ```

### Изменения в веб-морде не применяются на серверы

Смотри `_apply_services_sync()` в `web/app.py`. Он запускает
`scripts/add-service.sh` в `PROJECT_ROOT`. Если `add-service.sh` возвращает
ошибку — она попадёт в HTTP-ответ и во всплывашку. Частая причина — не
работает SSH к внешнему серверу (проверь `ssh root@<EXTERNAL_HOST> echo ok`).

---

## Структура проекта

```
morozovka-bridge/
├── config.env                     # источник истины (в .gitignore)
├── config.env.example
├── install.sh                     # базовая установка (ветка main)
├── install-web.sh                 # установка веб-морды (эта ветка)
├── uninstall.sh
├── scripts/                       # CLI-скрипты (используются и веб-мордой)
│   ├── lib.sh
│   ├── pi-setup.sh
│   ├── add-service.sh             # ★ вызывается из app.py
│   └── status.sh
├── templates/                     # шаблоны Nginx и systemd
│   ├── remote-setup.sh
│   ├── nginx-http.conf.tpl
│   ├── nginx-stream.conf.tpl
│   └── socat@.service
└── web/                           # ★ веб-морда
    ├── __init__.py
    ├── requirements.txt
    ├── manage.py                  # CLI: init-db, create-admin, import, ...
    ├── app.py                     # FastAPI: роуты, рендер
    ├── config.py                  # загрузка config.env
    ├── db.py                      # SQLModel + SQLite
    ├── models.py                  # User, Service, TestRun
    ├── auth.py                    # bcrypt + сессии + RBAC
    ├── chain_test.py              # 7-шаговое тестирование
    ├── config_manager.py          # sync БД ↔ config.env
    ├── morozovka-web.service      # systemd unit
    ├── templates/                 # Jinja2
    │   ├── base.html
    │   ├── login.html
    │   ├── dashboard.html
    │   ├── services.html
    │   ├── service_form.html
    │   ├── service_detail.html
    │   ├── users.html
    │   ├── user_form.html
    │   └── profile.html
    └── static/
        ├── css/app.css
        └── js/app.js
```

### Как это связано

- Веб-морда **не дублирует** логику CLI — она пересобирает `config.env` и
  вызывает `scripts/add-service.sh`.
- `config.env` — единый источник истины для сервисов и настроек сети.
  БД — источник истины для пользователей и истории тестов.
- `scripts/add-service.sh` идемпотентен — можно безопасно вызывать сколько
  угодно раз.

---

## Безопасность

- **Пароли** хранятся в виде bcrypt-хешей (cost 12).
- **Сессии** — подписанные куки через `itsdangerous`, `HttpOnly`, `SameSite=Lax`.
  Срок жизни — 7 дней (`WEB_SESSION_MAX_AGE`).
- **CSRF** — приложение принимает только POST на изменяющие роуты, куки
  `SameSite=Lax`. Для дополнительной защиты можно поставить reverse proxy
  с проверкой `Origin`.
- **`config.env`** имеет права `600` и не коммитится (см. `.gitignore`).
- **XSS** — все данные из внешних источников (`nc`, `ping`, `curl`) вставляются
  в DOM через `escapeHtml()`.
- **RBAC** — проверяется на каждом роуте, не только в UI. `viewer` не сможет
  отправить POST даже вручную.

> ⚠️ **Не выставляй морду наружу без HTTPS.** Пароль при логине уходит
> открытым текстом. Подними self-signed сертификат (см. [HTTPS вручную](#https-вручную))
> или поставь морду за reverse-proxy с TLS.

---

## Лицензия

MIT
