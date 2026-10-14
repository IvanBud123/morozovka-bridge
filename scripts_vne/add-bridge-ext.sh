#!/usr/bin/env bash
# Добавление проброса на внешнем сервере.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Запусти от root: sudo $0"
    exit 1
fi

echo "=== Добавление проброса на внешнем сервере ==="
echo

# Внешний порт
read -rp "Внешний порт (публично доступный, напр. 5050): " ext_port
[[ "$ext_port" =~ ^[0-9]+$ ]] || { echo "Неверный порт."; exit 1; }

if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "dpt:${ext_port} "; then
    echo "Порт ${ext_port} уже проброшен:"
    iptables -t nat -L PREROUTING -n | grep "dpt:${ext_port} "
    exit 1
fi

# VPN-порт Малинки
echo
read -rp "VPN-порт Малинки (тот, что указан в add-service-pi.sh, напр. 5050): " vpn_port
[[ "$vpn_port" =~ ^[0-9]+$ ]] || { echo "Неверный порт."; exit 1; }

# IP Малинки в VPN
PI_VPN_IP="10.8.0.2"
read -rp "IP Малинки в VPN (Enter = ${PI_VPN_IP}): " tmp
[[ -n "$tmp" ]] && PI_VPN_IP="$tmp"

# Проверка связи
echo
echo "Проверяю связь с ${PI_VPN_IP} ..."
if ping -c2 -W2 "$PI_VPN_IP" >/dev/null 2>&1; then
    echo "  OK — Малинка доступна."
else
    echo "  Малинка не пингуется."
    read -rp "Продолжить всё равно? (y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 1; }
fi

# Проверка порта
echo "Проверяю VPN-порт ${vpn_port} на Малинке ..."
if timeout 3 nc -zv "$PI_VPN_IP" "$vpn_port" >/dev/null 2>&1; then
    echo "  OK — порт отвечает."
else
    echo "  Порт ${vpn_port} на Малинке не отвечает."
    read -rp "Продолжить всё равно? (y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 1; }
fi

echo
echo "Добавляю правила iptables ..."
echo

# DNAT
iptables -t nat -A PREROUTING -p tcp --dport "$ext_port" -j DNAT --to-destination "${PI_VPN_IP}:${vpn_port}"
echo "  + DNAT        :${ext_port} → ${PI_VPN_IP}:${vpn_port}"

# FORWARD → Малинка
iptables -A FORWARD -p tcp -d "$PI_VPN_IP" --dport "$vpn_port" -j ACCEPT
echo "  + FORWARD     → ${PI_VPN_IP}:${vpn_port}"

# FORWARD ← Малинка
iptables -A FORWARD -p tcp -s "$PI_VPN_IP" --sport "$vpn_port" -m state --state ESTABLISHED,RELATED -j ACCEPT
echo "  + FORWARD     ← ${PI_VPN_IP}:${vpn_port}"

# MASQUERADE
iptables -t nat -A POSTROUTING -o tun0 -p tcp --dport "$vpn_port" -j MASQUERADE
echo "  + MASQUERADE  tun0 :${vpn_port}"

# Сохраняем
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1
    echo "  + iptables сохранены"
fi

echo
echo "Проверка правил:"
iptables -t nat -L PREROUTING -n -v | grep "dpt:${ext_port} "     && echo "    DNAT       ok"
iptables -L FORWARD -n -v | grep "dpt:${vpn_port} "               && echo "    FORWARD →  ok"
iptables -L FORWARD -n -v | grep "spt:${vpn_port} "               && echo "    FORWARD ←  ok"
iptables -t nat -L POSTROUTING -n -v | grep "dpt:${vpn_port} "    && echo "    MASQUERADE ok"

echo
echo "======================================================"
echo " Проброс добавлен."
echo "======================================================"
echo
echo "  Публично доступно:  http://<PUBLIC_IP>:${ext_port}/"
echo "  Прокидывает на:     ${PI_VPN_IP}:${vpn_port}"
echo
echo "  Не забудь открыть порт в firewall, если он есть:"
echo "    ufw allow ${ext_port}/tcp"
echo
