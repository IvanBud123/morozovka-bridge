# morozovka-bridge

Проброс сервисов (HTTP и TCP) из изолированной сети вуза наружу через
сервер с белым IP. Работает поверх OpenVPN без необходимости статического
IP на Raspberry Pi.

## Схема работы

```
Интернет
   │
   ▼
[ Внешний сервер с белым IP ]
   │  Nginx (http → reverse proxy, tcp → stream)
   │
   ▼  OpenVPN (tun0, UDP)
[ Raspberry Pi ]
   │  socat-форвардеры
   │
   ▼  Ethernet (192.168.50.0/24)
[ Коммутатор ]
   ├── Сервер 1 (192.168.50.2)
   └── Сервер 2 (192.168.50.3)
```

## Требования

| Узел | Что нужно |
|---|---|
| Raspberry Pi | Raspberry Pi OS / Ubuntu, доступ в интернет (USB-модем), eth0 в вузовской сети |
| Внешний сервер | Linux с белым IP, root-доступ по SSH |
| Внутренние серверы | Статические IP, шлюз — Малинка (`192.168.50.1`) |

## Быстрый старт

1. **Подготовьте внутренние серверы.** На каждом сервере в вузе:
   - Статический IP в подсети `192.168.50.0/24` (например, `192.168.50.2`)
   - Шлюз (gateway) — `192.168.50.1` (Малинка)
   - DNS — `8.8.8.8`, `1.1.1.1`

2. **Настройте Малинку.** На её `eth0` — статический IP `192.168.50.1/24`.

3. **Склонируйте репозиторий на Малинку:**
   ```bash
   git clone https://github.com/IvanBud123/morozovka-bridge.git
   cd morozovka-bridg
   ```

4. **Заполните конфиг:**
   ```bash
   cp config.env.example config.env
   nano config.env
   ```

5. **Запустите установку:**
   ```bash
   sudo ./install.sh
   ```

6. **Проверьте статус:**
   ```bash
   sudo ./scripts/status.sh
   ```

## Формат SERVICES

Каждая строка описывает один проброс:

```
имя|домен|внутренний_ip|внутренний_порт|vpn_порт|тип|внешний_порт
```

| Поле | Описание |
|---|---|
| `имя` | Идентификатор (латиница, без пробелов) |
| `домен` | Для http — домен или `_`; для tcp — `_` |
| `внутренний_ip` | IP сервера в вузе |
| `внутренний_порт` | Порт сервиса на этом сервере |
| `vpn_порт` | Порт, который слушает socat на Малинке (bind на VPN-IP) |
| `тип` | `http` (reverse proxy) или `tcp` (stream) |
| `внешний_порт` | Порт, открытый наружу на внешнем сервере |

### HTTP vs TCP

- **`http`** — Nginx как reverse proxy. Пробрасывает заголовки `Host`,
  `X-Real-IP`, `X-Forwarded-For`. Подходит для GitTea, Wiki, веб-приложений.
- **`tcp`** — Nginx stream. Просто пробрасывает байты. Подходит для SSH,
  MySQL, Redis, любых бинарных протоколов.

### Примеры

```bash
# GitTea на 3000 наружу на 8080
"gittea|_|192.168.50.2|3000|8080|http|8080"

# Веб-страница на 9999 наружу на 9654
"webapp|_|192.168.50.2|9999|8081|http|9654"

# SSH на 22 наружу на 8022
"ssh-srv1|_|192.168.50.2|22|8022|tcp|8022"
```

## Добавить новый сервис после установки

1. Добавьте строку в массив `SERVICES` в `config.env`.
2. Запустите:
   ```bash
   sudo ./scripts/add-service.sh
   ```

Скрипт идемпотентный — уже настроенные сервисы не будут тронуты.

## Удалить всё

```bash
sudo ./uninstall.sh
```

## Firewall на внешнем сервере

Скрипт **не трогает** firewall, чтобы не сломать существующие правила.
Откройте порты вручную:

```bash
# iptables
sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
sudo iptables -A INPUT -p udp --dport 1194 -j ACCEPT
```

## HTTPS

Из коробки всё работает на HTTP/TCP. Если нужен HTTPS:
- Сгенерируйте self-signed сертификат и добавьте `ssl_certificate` в
  `/etc/nginx/sites-available/<имя>.conf` на внешнем сервере.
- Либо поставьте TLS-терминацию внутри (на вузовском сервере), а наружу
  пробрасывайте через `type=tcp`.

## Troubleshooting

| Проблема | Что проверить |
|---|---|
| VPN не поднимается | `sudo journalctl -u openvpn-client@client -f` на Малинке |
| Сервис не открывается | `systemctl status socat@<имя>` на Малинке |
| Nginx отдаёт 502 | `ping 10.8.0.2` с внешнего сервера |
| Порт закрыт | Firewall на внешнем сервере |
| TCP-сервис не работает | `nc -vz <external_host> <external_port>` |

## Структура

```
morozovka-bridge/
├── install.sh              # главный установщик
├── uninstall.sh            # удаление
├── config.env.example      # шаблон конфига
├── scripts/
│   ├── lib.sh              # общие функции
│   ├── pi-setup.sh         # настройка Малинки
│   ├── add-service.sh      # добавление сервисов
│   └── status.sh           # статус
└── templates/
    ├── remote-setup.sh     # скрипт для внешнего сервера
    ├── nginx-http.conf.tpl # reverse proxy
    ├── nginx-stream.conf.tpl # TCP stream
    └── socat@.service      # systemd-юнит для socat
```

## Лицензия

MIT
