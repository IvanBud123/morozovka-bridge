#!/usr/bin/env bash
# Удаление morozovka-bridge с Малинки и внешнего сервера.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck disable=SC1091
source scripts/lib.sh
require_root
load_config

warn "Это удалит конфигурацию morozovka-bridge на Малинке и на ${EXTERNAL_HOST}."
read -rp "Продолжить? (yes/no): " ans
[[ "$ans" == "yes" ]] || exit 0

# ---------- Малинка ----------
log "Останавливаем и удаляем socat-сервисы"
for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name _ _ _ _ _ _ <<< "$entry"
    systemctl disable --now "socat@${name}" 2>/dev/null || true
    rm -f "/etc/morozovka-bridge/services/${name}.env"
done
rm -f /etc/systemd/system/socat@.service
rmdir /etc/morozovka-bridge/services 2>/dev/null || true
rmdir /etc/morozovka-bridge 2>/dev/null || true
systemctl daemon-reload

log "Останавливаем OpenVPN-клиент"
systemctl disable --now openvpn-client@client 2>/dev/null || true
rm -f /etc/openvpn/client/client.conf

rm -f /etc/sysctl.d/99-morozovka-bridge.conf

# ---------- Внешний сервер ----------
log "Удаляем конфигурацию на внешнем сервере"
ssh_remote "bash -s" <<'REMOTE_EOF' || warn "Часть команд на внешнем сервере не выполнилась"
set +e
rm -f /etc/nginx/sites-enabled/morozovka-*.conf /etc/nginx/sites-available/morozovka-*.conf
rm -f /etc/nginx/stream.d/morozovka-*.conf
nginx -t 2>/dev/null && systemctl reload nginx

systemctl disable --now openvpn-server@server
rm -rf /etc/openvpn/server /etc/openvpn/easy-rsa /root/morozovka-bridge-client
rm -f /root/morozovka-bridge-remote.env /root/morozovka-bridge-remote-setup.sh
rm -f /etc/iptables/rules.v4
REMOTE_EOF

ok "Удаление завершено."
