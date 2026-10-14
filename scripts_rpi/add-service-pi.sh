#!/usr/bin/env bash
# Добавление нового socat-сервиса на Малинке.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Запусти от root: sudo $0"
    exit 1
fi

echo "=== Добавление socat-сервиса на Малинке ==="
echo

# Куда форвардить
read -rp "Куда форвардить (IP:порт, напр. 192.168.50.3:5000, 127.0.0.1:22): " dest
if [[ ! "$dest" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
    echo "Неверный формат. Пример: 192.168.50.3:5000"
    exit 1
fi
dest_ip="${dest%:*}"
dest_port="${dest#*:}"

echo
echo "Проверяю ${dest} ..."
if timeout 3 nc -zv "$dest_ip" "$dest_port" >/dev/null 2>&1; then
    echo "  OK — порт отвечает."
else
    echo "  Порт НЕ отвечает."
    read -rp "Продолжить всё равно? (y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 1; }
fi

# VPN-порт
echo
read -rp "VPN-порт на Малинке (bind на tun0, напр. 5050): " vpn_port
[[ "$vpn_port" =~ ^[0-9]+$ ]] || { echo "Неверный порт."; exit 1; }

if ss -tlnp 2>/dev/null | grep -q ":${vpn_port} "; then
    echo "Порт ${vpn_port} уже занят на Малинке:"
    ss -tlnp | grep ":${vpn_port} "
    exit 1
fi

# Имя
echo
read -rp "Название сервиса (латиница, без пробелов, напр. webapp-srv3): " name
if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Только буквы, цифры, подчёркивание, дефис."
    exit 1
fi

unit="socat-${name}"
unit_file="/etc/systemd/system/${unit}.service"

if [[ -f "$unit_file" ]]; then
    echo "Сервис ${unit} уже существует: ${unit_file}"
    exit 1
fi

# IP в tun0
PI_VPN_IP=$(ip -4 addr show tun0 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1 || echo "")
if [[ -z "$PI_VPN_IP" ]]; then
    echo "tun0 не поднят. Сначала подними VPN."
    exit 1
fi

# Создаём unit
cat > "$unit_file" <<EOF
[Unit]
Description=socat forwarder (VPN:${vpn_port} -> ${dest_ip}:${dest_port})
After=network-online.target openvpn-client@client.service
Wants=network-online.target
Requires=openvpn-client@client.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/fuser -k ${vpn_port}/tcp
ExecStart=/usr/bin/socat -d -d TCP-LISTEN:${vpn_port},fork,reuseaddr,bind=${PI_VPN_IP} TCP:${dest_ip}:${dest_port}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$unit"

sleep 1

if systemctl is-active --quiet "$unit"; then
    echo
    echo "======================================================"
    echo " Сервис ${unit} запущен."
    echo "======================================================"
    echo
    echo "  • destination:      ${dest_ip}:${dest_port}"
    echo "  • VPN-порт Малинки: ${PI_VPN_IP}:${vpn_port}"
    echo "  • unit-файл:        ${unit_file}"
    echo
    echo "  На внешнем сервере:"
    echo "    - Запусти add-bridge-ext.sh"
    echo "    - Укажи VPN-порт ${vpn_port}"
    echo "    - Укажи внешний порт (можно тот же или свой)"
    echo
else
    echo "Сервис не запустился. Смотри: journalctl -u ${unit} -n 30"
    exit 1
fi
