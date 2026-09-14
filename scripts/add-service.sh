#!/usr/bin/env bash
# Идемпотентно добавляет/обновляет сервисы из config.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
require_root
load_config
validate_services

# Проверка SSH к внешнему серверу
ssh_remote "echo ok" >/dev/null || die "SSH к ${EXTERNAL_HOST} не работает"
ok "SSH-соединение с внешним сервером есть"

# ---------- 1. socat на Малинке ----------
log "Настраиваем socat-сервисы на Малинке"
for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name domain internal_ip internal_port vpn_port type external_port <<< "$entry"

    cat > "/etc/morozovka-bridge/services/${name}.env" <<EOF
VPN_PORT=${vpn_port}
PI_VPN_IP=${PI_VPN_IP}
INTERNAL_IP=${internal_ip}
INTERNAL_PORT=${internal_port}
EOF
    chmod 600 "/etc/morozovka-bridge/services/${name}.env"

    systemctl enable "socat@${name}" >/dev/null 2>&1 || true
    systemctl restart "socat@${name}"
    ok "  socat@${name} → ${internal_ip}:${internal_port} (VPN :${vpn_port})"
done

# ---------- 2. Nginx на внешнем сервере ----------
log "Настраиваем Nginx на внешнем сервере"

# Чистим старые конфиги от morozovka-bridge, которые больше не нужны
ssh_remote "rm -f /etc/nginx/sites-enabled/morozovka-*.conf /etc/nginx/sites-available/morozovka-*.conf /etc/nginx/stream.d/morozovka-*.conf"

for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name domain internal_ip internal_port vpn_port type external_port <<< "$entry"
    fullname="morozovka-${name}"

    if [[ "$type" == "http" ]]; then
        [[ "$domain" == "_" ]] && domain="_"
        rendered=$(SERVICE_NAME="$name" DOMAIN="$domain" \
            PI_VPN_IP="$PI_VPN_IP" VPN_PORT="$vpn_port" \
            EXTERNAL_PORT="$external_port" \
            envsubst '$SERVICE_NAME $DOMAIN $PI_VPN_IP $VPN_PORT $EXTERNAL_PORT' \
            < "$PROJECT_ROOT/templates/nginx-http.conf.tpl")
        echo "$rendered" | ssh_remote "cat > /etc/nginx/sites-available/${fullname}.conf && ln -sf /etc/nginx/sites-available/${fullname}.conf /etc/nginx/sites-enabled/${fullname}.conf"
        ok "  nginx http ${fullname}: ${external_port} → ${PI_VPN_IP}:${vpn_port}"
    else
        rendered=$(SERVICE_NAME="$name" \
            PI_VPN_IP="$PI_VPN_IP" VPN_PORT="$vpn_port" \
            EXTERNAL_PORT="$external_port" \
            envsubst '$SERVICE_NAME $PI_VPN_IP $VPN_PORT $EXTERNAL_PORT' \
            < "$PROJECT_ROOT/templates/nginx-stream.conf.tpl")
        echo "$rendered" | ssh_remote "cat > /etc/nginx/stream.d/${fullname}.conf"
        ok "  nginx stream ${fullname}: ${external_port} → ${PI_VPN_IP}:${vpn_port}"
    fi
done

ssh_remote "nginx -t && systemctl reload nginx" || die "Nginx не принял конфиг"
ok "Nginx перезагружен"

echo
ok "Готово. Проверьте: sudo ./scripts/status.sh"
