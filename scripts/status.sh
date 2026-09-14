#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
require_root
load_config

echo "============================================"
echo "  morozovka-bridge status"
echo "============================================"
echo

echo "── Малинка ─────────────────────────────────"
printf "  %-20s " "OpenVPN клиент:"
systemctl is-active --quiet openvpn-client@client && echo -e "${GREEN}active${NC}" || echo -e "${RED}FAIL${NC}"

printf "  %-20s " "tun0:"
ip -o addr show tun0 2>/dev/null | awk '{print $4}' || echo -e "${RED}нет${NC}"
echo

echo "── socat-сервисы ──────────────────────────"
for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name _ _ _ _ _ _ <<< "$entry"
    printf "  %-20s " "socat@${name}:"
    systemctl is-active --quiet "socat@${name}" && echo -e "${GREEN}active${NC}" || echo -e "${RED}FAIL${NC}"
done
echo

echo "── Внешний сервер ─────────────────────────"
printf "  %-20s " "OpenVPN сервер:"
ssh_remote "systemctl is-active --quiet openvpn-server@server" && echo -e "${GREEN}active${NC}" || echo -e "${RED}FAIL${NC}"

printf "  %-20s " "Nginx:"
ssh_remote "systemctl is-active --quiet nginx" && echo -e "${GREEN}active${NC}" || echo -e "${RED}FAIL${NC}"

printf "  %-20s " "Доступность Pi:"
ssh_remote "ping -c1 -W2 ${PI_VPN_IP}" >/dev/null 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${RED}FAIL${NC}"
echo

echo "── Сервисы ────────────────────────────────"
for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name domain internal_ip internal_port vpn_port type external_port <<< "$entry"
    printf "  %-15s %s://%s:%s  →  %s:%s\n" \
        "$name" "$type" "$EXTERNAL_HOST" "$external_port" "$internal_ip" "$internal_port"
done
echo
