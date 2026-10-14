#!/usr/bin/env bash
# Удаление проброса на внешнем сервере.
# Показывает активные DNAT-правила, даёт выбрать порт, удаляет все связанные правила.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Запусти от root: sudo $0"
    exit 1
fi

echo "=== Удаление проброса на внешнем сервере ==="
echo

# Собираем DNAT-правила из iptables-save — там удобнее парсить
mapfile -t dnat_lines < <(iptables-save -t nat 2>/dev/null | grep -- '-A PREROUTING' | grep 'DNAT' || true)

if [[ ${#dnat_lines[@]} -eq 0 ]]; then
    echo "Нет активных DNAT-правил."
    exit 0
fi

declare -a pick_ports=()
declare -a pick_dests=()

echo "Активные проброшенные порты:"
echo

for line in "${dnat_lines[@]}"; do
    ext_port=$(echo "$line" | grep -oP -- '--dport \K[0-9]+' | head -1 || echo "?")
    dest=$(echo "$line" | grep -oP -- '--to-destination \K[0-9.]+:[0-9]+' | head -1 || echo "?")

    n=$(( ${#pick_ports[@]} + 1 ))
    printf "  [%d] внешний порт %-6s → %s\n" "$n" "$ext_port" "$dest"

    pick_ports+=("$ext_port")
    pick_dests+=("$dest")
done
echo

read -rp "Номер порта для удаления (q — выход): " choice
[[ "$choice" == "q" ]] && exit 0
[[ "$choice" =~ ^[0-9]+$ ]] || { echo "Неверный ввод."; exit 1; }

idx=$((choice - 1))
if [[ $idx -lt 0 || $idx -ge ${#pick_ports[@]} ]]; then
    echo "Неверный номер."
    exit 1
fi

ext_port="${pick_ports[$idx]}"
dest="${pick_dests[$idx]}"
target_ip="${dest%:*}"
target_port="${dest#*:}"

echo
echo "Удаляем правила для порта ${ext_port} → ${dest}"
echo

# DNAT
while iptables -t nat -C PREROUTING -p tcp --dport "$ext_port" -j DNAT --to-destination "$dest" 2>/dev/null; do
    iptables -t nat -D PREROUTING -p tcp --dport "$ext_port" -j DNAT --to-destination "$dest"
done
echo "  - DNAT удалён"

# FORWARD → Малинка
while iptables -C FORWARD -p tcp -d "$target_ip" --dport "$target_port" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -p tcp -d "$target_ip" --dport "$target_port" -j ACCEPT
done
echo "  - FORWARD (в сторону Малинки) удалён"

# FORWARD ← Малинка
while iptables -C FORWARD -p tcp -s "$target_ip" --sport "$target_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -p tcp -s "$target_ip" --sport "$target_port" -m state --state ESTABLISHED,RELATED -j ACCEPT
done
echo "  - FORWARD (обратно) удалён"

# MASQUERADE
while iptables -t nat -C POSTROUTING -o tun0 -p tcp --dport "$target_port" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -o tun0 -p tcp --dport "$target_port" -j MASQUERADE
done
echo "  - MASQUERADE удалён"

# INPUT (если был добавлен)
iptables -D INPUT -p tcp --dport "$ext_port" -j ACCEPT 2>/dev/null || true

# Сохраняем
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1
    echo "  - iptables сохранены"
fi

echo
echo "======================================================"
echo " Порт ${ext_port} больше не пробрасывается."
echo "======================================================"
echo
