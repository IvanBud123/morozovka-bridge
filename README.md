# morozovka-bridge

Проброс сервисов из изолированной сети вуза в интернет через внешний сервер с белым IP.

## Что это

Raspberry Pi с USB-модемом держит постоянный OpenVPN-туннель до внешнего сервера. Через этот туннель пробрасываются TCP-сервисы из локальной сети (`192.168.50.0/24`) в интернет: SSH, Gitea, веб-приложения, что угодно.

## Схема

```
Пользователь → 31.128.43.79:<external_port>
                    ↓ DNAT
              10.8.0.2:<vpn_port>  (туннель)
                    ↓ socat
              192.168.50.X:<dest_port>
```

## Что внутри

- **4 CLI-скрипта** — для управления пробросами через командную строку.
- **Веб-морда** — та же функциональность, но в браузере, плюс мониторинг всей инфраструктуры.

## Структура репозитория

```
morozovka-bridge/
├── app.py                      # Flask-приложение веб-морды
├── bridge-webui.service        # systemd-юнит для веб-морды
├── collector.sh                # сборщик метрик хоста
├── install.sh                  # установщик веб-морды
├── LICENSE                     # MIT
├── requirements.txt            # Python-зависимости
├── scripts_rpi/                # скрипты для Малинки
│   ├── add-service-pi.sh
│   └── remove-service-pi.sh
├── scripts_vne/                # скрипты для внешнего сервера
│   ├── add-bridge-ext.sh
│   └── remove-bridge-ext.sh
└── templates/                  # HTML-шаблоны веб-морды
    ├── index.html
    └── metrics.html
```

## Быстрый старт

1. Клонировать репозиторий на каждый хост:

```bash
git clone https://github.com/IvanBud123/morozovka-bridge.git
cd morozovka-bridge
```

2. На **Малинке** — использовать скрипты из `scripts_rpi/`.
3. На **внешнем сервере** — скрипты из `scripts_vne/`.
4. На **сервере 3** — установить веб-морду:

```bash
sudo ./install.sh
```

## Документация

Вся документация — в [Wiki репозитория](https://github.com/IvanBud123/morozovka-bridge/wiki):

- [Архитектура](https://github.com/IvanBud123/morozovka-bridge/wiki/Архитектура)
- [Развёртывание](https://github.com/IvanBud123/morozovka-bridge/wiki/Развёртывание)
- [Скрипты](https://github.com/IvanBud123/morozovka-bridge/wiki/Скрипт-add-service-pi)
- [Веб-интерфейс](https://github.com/IvanBud123/morozovka-bridge/wiki/Веб-интерфейс)
- [Troubleshooting](https://github.com/IvanBud123/morozovka-bridge/wiki/Troubleshooting)

## Лицензия

MIT — см. [LICENSE](LICENSE).
