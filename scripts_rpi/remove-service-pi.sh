#!/usr/bin/env bash
# Удаление socat-сервиса на Малинке.
# Показывает список активных socat-*.service, даёт выбрать и удаляет.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Запусти от root: sudo $0"
    exit 1
fi

echo "=== Удаление socat-сервиса на Малинке ==="
echo

# Собираем список unit-файлов socat-*.service
mapfile -t units < <(systemctl list-unit-files 'socat-*.service' --no-legend 2>/dev/null | awk '{print $1}' | sort)

if [[ ${#units[@]} -eq 0 ]]; then
    echo "Нет установленных socat-сервисов."
    exit 0
fi

echo "Установленные socat-сервисы:"
echo

declare -a pick_units=()
declare -a pick_ports=()
declare -a pick_dests=()
declare -a pick_states=()

for unit in "${units[@]}"; do
    exec_line=$(systemctl show -p ExecStart --value "$unit" 2>/dev/null || echo "")
    bind_port=$(echo "$exec_line" | grep -oP 'TCP-LISTEN:\K[0-9]+' | head -1 || echo "?")
    dest=$(echo "$exec_line" | grep -oP 'TCP:\K[0-9.]+:[0-9]+' | head -1 || echo "?")
    state=$(systemctl is-active "$unit" 2>/dev/null || echo "inactive")

    n=$(( ${#pick_units[@]} + 1 ))
    echo "  [$n] $unit"
    echo "      VPN-порт: ${bind_port}   →   ${dest}   [${state}]"

    pick_units+=("$unit")
    pick_ports+=("$bind_port")
    pick_dests+=("$dest")
    pick_states+=("$state")
done
echo

read -rp "Номер сервиса для удаления (q — выход): " choice
[[ "$choice" == "q" ]] && exit 0
[[ "$choice" =~ ^[0-9]+$ ]] || { echo "Неверный ввод."; exit 1; }

idx=$((choice - 1))
if [[ $idx -lt 0 || $idx -ge ${#pick_units[@]} ]]; then
    echo "Неверный номер."
    exit 1
fi

unit="${pick_units[$idx]}"
vpn_port="${pick_ports[$idx]}"
dest="${pick_dests[$idx]}"

echo
echo "Удаляем $unit ..."
systemctl disable --now "$unit" 2>/dev/null || true
rm -f "/etc/systemd/system/${unit}"
systemctl daemon-reload

echo
echo "======================================================"
echo " Сервис ${unit} удалён."
echo "======================================================"
echo
echo "  • VPN-порт на Малинке: ${vpn_port}  — теперь свободен"
echo "  • Форвардил на:        ${dest}"
echo
echo "  На внешнем сервере:"
echo "    - Запусти remove-bridge-ext.sh"
echo "    - Выбери внешний порт, который был связан с VPN-портом ${vpn_port}"
echo
