#!/usr/bin/env bash
# Настройка Raspberry Pi: OpenVPN-клиент + socat-сервисы.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_config

log "Установка пакетов"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openvpn socat curl

# ---------- OpenVPN-клиент ----------
mkdir -p /etc/openvpn/client
if [[ -f /tmp/morozovka-bridge-client/client.conf ]]; then
    cp /tmp/morozovka-bridge-client/client.conf /etc/openvpn/client/client.conf
    chmod 600 /etc/openvpn/client/client.conf
fi

systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

log "Ожидание tun0..."
for i in {1..30}; do
    ip -o link show tun0 &>/dev/null && break
    sleep 1
done
ip -o link show tun0 &>/dev/null || die "tun0 не поднялся. Проверьте /var/log/syslog."

# ---------- ip_forward ----------
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-morozovka-bridge.conf
sysctl -p /etc/sysctl.d/99-morozovka-bridge.conf

# ---------- systemd unit для socat ----------
mkdir -p /etc/morozovka-bridge/services
cp "$PROJECT_ROOT/templates/socat@.service" /etc/systemd/system/socat@.service
systemctl daemon-reload

# ---------- socat-сервисы ----------
for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name domain internal_ip internal_port vpn_port type external_port <<< "$entry"
    log "Сервис: $name ($internal_ip:$internal_port → VPN :$vpn_port)"

    cat > "/etc/morozovka-bridge/services/${name}.env" <<EOF
VPN_PORT=${vpn_port}
PI_VPN_IP=${PI_VPN_IP}
INTERNAL_IP=${internal_ip}
INTERNAL_PORT=${internal_port}
EOF
    chmod 600 "/etc/morozovka-bridge/services/${name}.env"

    systemctl enable "socat@${name}"
    systemctl restart "socat@${name}"
done

ok "Малинка настроена."
