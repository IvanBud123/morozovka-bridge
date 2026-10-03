#!/usr/bin/env bash
# ============================================================
#  morozovka-bridge — главный установщик
#  Запускать на Raspberry Pi: sudo ./install.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
source scripts/lib.sh
require_root
load_config
validate_services

# ---------- 0. Проверка локальной сети ----------
log "Проверка ${PI_LAN_INTERFACE} (ожидаем ${PI_LAN_IP})"
ip -o addr show dev "${PI_LAN_INTERFACE}" | grep -q "${PI_LAN_IP}" \
    || die "На ${PI_LAN_INTERFACE} нет IP ${PI_LAN_IP}. Настройте сеть перед запуском."

# ---------- 1. SSH-ключ к внешнему серверу ----------
if [[ ! -f /root/.ssh/id_ed25519 ]]; then
    log "Генерация SSH-ключа"
    ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -C "morozovka-bridge@$(hostname)"
fi

if ssh_remote "true" >/dev/null 2>&1; then
    ok "SSH-ключ уже работает"
else
    log "SSH-ключ не установлен. Копируем публичный ключ на ${EXTERNAL_HOST}"

    if [[ -n "${EXTERNAL_SSH_PASSWORD:-}" ]]; then
        if ! command -v sshpass >/dev/null 2>&1; then
            log "Установка sshpass"
            apt-get install -y -qq sshpass >/dev/null
        fi
        export SSHPASS="${EXTERNAL_SSH_PASSWORD}"
        if ! sshpass -e ssh-copy-id \
                -o StrictHostKeyChecking=accept-new \
                -o UserKnownHostsFile=/root/.ssh/known_hosts \
                -p "${EXTERNAL_SSH_PORT}" \
                "${EXTERNAL_SSH_USER}@${EXTERNAL_HOST}" >/dev/null 2>&1; then
            unset SSHPASS
            die "ssh-copy-id не сработал. Проверь EXTERNAL_SSH_USER и EXTERNAL_SSH_PASSWORD в config.env"
        fi
        unset SSHPASS
    else
        warn "EXTERNAL_SSH_PASSWORD не задан — введи пароль вручную (один раз)"
        ssh-copy-id \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/root/.ssh/known_hosts \
            -p "${EXTERNAL_SSH_PORT}" \
            "${EXTERNAL_SSH_USER}@${EXTERNAL_HOST}" \
            || die "ssh-copy-id не сработал"
    fi

    ssh_remote "true" >/dev/null 2>&1 \
        || die "Ключ скопирован, но SSH всё ещё требует пароль. Проверь sshd на ${EXTERNAL_HOST}."
    ok "SSH-ключ установлен"
fi

# ---------- 2. Настройка внешнего сервера ----------
log "Готовим env-файл для внешнего сервера"
REMOTE_ENV=/tmp/morozovka-bridge-remote.env
cat > "$REMOTE_ENV" <<EOF
VPN_PORT='${VPN_PORT}'
VPN_PROTO='${VPN_PROTO}'
VPN_NETWORK='${VPN_NETWORK}'
VPN_NETMASK='${VPN_NETMASK}'
EXTERNAL_VPN_IP='${EXTERNAL_VPN_IP}'
PI_VPN_IP='${PI_VPN_IP}'
EOF

scp_to_remote "$REMOTE_ENV" /root/morozovka-bridge-remote.env
scp_to_remote templates/remote-setup.sh /root/morozovka-bridge-remote-setup.sh

log "Запуск remote-setup.sh на внешнем сервере (может занять несколько минут)"
# remote-setup.sh сам себе загрузит env-файл в начале.
# Явно вызываем bash, чтобы не зависеть от шелла root на удалённой стороне.
ssh_remote "bash /root/morozovka-bridge-remote-setup.sh"
ok "Внешний сервер настроен"

# ---------- 3. Забираем клиентские файлы OpenVPN ----------
log "Забираем клиентские файлы с внешнего сервера"
rm -rf /tmp/morozovka-bridge-client
mkdir -p /tmp/morozovka-bridge-client
scp_from_remote "/root/morozovka-bridge-client/ca.crt"     /tmp/morozovka-bridge-client/
scp_from_remote "/root/morozovka-bridge-client/client.crt" /tmp/morozovka-bridge-client/
scp_from_remote "/root/morozovka-bridge-client/client.key" /tmp/morozovka-bridge-client/
scp_from_remote "/root/morozovka-bridge-client/ta.key"     /tmp/morozovka-bridge-client/

log "Рендерим client.conf"
cat > /tmp/morozovka-bridge-client/client.conf <<EOF
client
dev tun
proto ${VPN_PROTO}
remote ${EXTERNAL_HOST} ${VPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
tls-version-min 1.2
verb 3

<ca>
$(cat /tmp/morozovka-bridge-client/ca.crt)
</ca>
<cert>
$(cat /tmp/morozovka-bridge-client/client.crt)
</cert>
<key>
$(cat /tmp/morozovka-bridge-client/client.key)
</key>
<tls-auth>
$(cat /tmp/morozovka-bridge-client/ta.key)
</tls-auth>
key-direction 1
EOF
chmod 600 /tmp/morozovka-bridge-client/*
ok "Клиентский конфиг готов"

# ---------- 4. Настройка Малинки ----------
log "Настройка Малинки (OpenVPN клиент + socat)"
bash scripts/pi-setup.sh
ok "Малинка настроена"

# ---------- 5. Nginx на внешнем сервере ----------
log "Настраиваем Nginx и порты на внешнем сервере"
bash scripts/add-service.sh

# ---------- 6. Итог ----------
echo
ok "============================================"
ok " Установка завершена!"
ok "============================================"
echo
bash scripts/status.sh
echo
warn "Не забудьте открыть порты на внешнем сервере вручную:"
for entry in "${SERVICES[@]}"; do
    IFS='|' read -r _ _ _ _ _ _ external_port <<< "$entry"
    echo "    ufw allow ${external_port}/tcp"
done
echo "    ufw allow ${VPN_PORT}/${VPN_PROTO}"
echo
