#!/usr/bin/env bash
# ============================================================
#  morozovka-bridge — очистка состояния
#
#  Что делает:
#    - на Малинке: останавливает openvpn-client@client и все socat@*,
#      удаляет их файлы и systemd-юнит, чистит /etc/morozovka-bridge/
#      и /etc/vuz-bridge/ (старое имя), /etc/sysctl.d/99-*bridge*.conf,
#      /tmp/morozovka-bridge-* и /tmp/vuz-bridge-*
#    - на внешнем сервере (по SSH): останавливает openvpn-server@server,
#      чистит /etc/openvpn/server, /etc/openvpn/easy-rsa, /root/*-bridge-*,
#      Nginx-конфиги morozovka-*/vuz-* в sites-enabled и stream.d,
#      правила iptables MASQUERADE и FORWARD для VPN-подсети
#
#  Что НЕ делает:
#    - не удаляет пакеты (openvpn, nginx, socat)
#    - не трогает SSH-ключи
#    - не трогает firewall-правила для внешних портов (их ты открывал руками)
#    - не удаляет папку с проектом
#
#  Использование:
#    sudo ./scripts/cleanup.sh           # очистка с подтверждением
#    sudo ./scripts/cleanup.sh --yes     # без вопросов
#    sudo ./scripts/cleanup.sh --pi-only # только Малинка
#    sudo ./scripts/cleanup.sh --ext-only# только внешний сервер
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
require_root

# ---------- Парсинг аргументов ----------
ASSUME_YES=0
PI_ONLY=0
EXT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)   ASSUME_YES=1 ;;
        --pi-only)  PI_ONLY=1 ;;
        --ext-only) EXT_ONLY=1 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "Неизвестный аргумент: $arg" ;;
    esac
done

# ---------- Загрузка config (не критично) ----------
if [[ -f "$PROJECT_ROOT/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/config.env" 2>/dev/null || true
fi

# VPN_NETWORK нужен только для очистки iptables.
VPN_NETWORK="${VPN_NETWORK:-10.8.0.0}"

# ---------- Подтверждение ----------
echo
warn "============================================"
warn "  morozovka-bridge — очистка состояния"
warn "============================================"
echo
if [[ "$EXT_ONLY" -eq 0 ]]; then
    echo "  ${BLUE}[Малинка]${NC}"
    echo "    - остановить openvpn-client@client и все socat@*"
    echo "    - удалить /etc/openvpn/client/client.conf"
    echo "    - удалить /etc/morozovka-bridge/ и /etc/vuz-bridge/"
    echo "    - удалить /etc/systemd/system/socat@.service"
    echo "    - удалить /etc/sysctl.d/99-*bridge*.conf"
    echo "    - удалить /tmp/*-bridge-*"
fi
if [[ "$PI_ONLY" -eq 0 && -n "${EXTERNAL_HOST:-}" ]]; then
    echo "  ${BLUE}[Внешний сервер ${EXTERNAL_HOST}]${NC}"
    echo "    - остановить openvpn-server@server"
    echo "    - удалить /etc/openvpn/server, /etc/openvpn/easy-rsa"
    echo "    - удалить Nginx-конфиги morozovka-* и vuz-*"
    echo "    - удалить /root/*-bridge-*"
    echo "    - снять iptables-правила для ${VPN_NETWORK}/24"
fi
echo
if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -rp "Продолжить? (yes/no): " ans
    [[ "$ans" == "yes" ]] || { echo "Отменено."; exit 0; }
fi

# ============================================================
#  ЛОКАЛЬНАЯ ОЧИСТКА (Малинка)
# ============================================================
if [[ "$EXT_ONLY" -eq 0 ]]; then
    echo
    log "=== Очистка Малинки ==="

    # --- socat-сервисы ---
    if systemctl list-unit-files 'socat@*.service' --no-legend 2>/dev/null | grep -q socat@; then
        log "Останавливаем socat@*"
        while read -r unit _; do
            [[ -z "$unit" ]] && continue
            systemctl disable --now "$unit" 2>/dev/null || true
            echo "  - $unit"
        done < <(systemctl list-unit-files 'socat@*.service' --no-legend | awk '{print $1}')
    else
        log "socat@* не найдены"
    fi

    # --- systemd unit ---
    if [[ -f /etc/systemd/system/socat@.service ]]; then
        log "Удаляем /etc/systemd/system/socat@.service"
        rm -f /etc/systemd/system/socat@.service
        systemctl daemon-reload
    fi

    # --- openvpn-client ---
    if systemctl list-unit-files 'openvpn-client@*.service' --no-legend 2>/dev/null | grep -q openvpn-client@; then
        log "Останавливаем openvpn-client@*"
        while read -r unit _; do
            [[ -z "$unit" ]] && continue
            systemctl disable --now "$unit" 2>/dev/null || true
            echo "  - $unit"
        done < <(systemctl list-unit-files 'openvpn-client@*.service' --no-legend | awk '{print $1}')
    fi

    if [[ -f /etc/openvpn/client/client.conf ]]; then
        log "Удаляем /etc/openvpn/client/client.conf"
        rm -f /etc/openvpn/client/client.conf
    fi

    # --- /etc/morozovka-bridge и /etc/vuz-bridge ---
    for d in /etc/morozovka-bridge /etc/vuz-bridge; do
        if [[ -d "$d" ]]; then
            log "Удаляем $d"
            rm -rf "$d"
        fi
    done

    # --- sysctl ---
    for f in /etc/sysctl.d/99-morozovka-bridge.conf /etc/sysctl.d/99-vuz-bridge.conf; do
        if [[ -f "$f" ]]; then
            log "Удаляем $f"
            rm -f "$f"
        fi
    done

    # --- /tmp ---
    log "Чистим /tmp от артефактов morozovka-bridge"
    rm -rf /tmp/morozovka-bridge-* /tmp/vuz-bridge-*
    rm -f  /tmp/morozovka-bridge-remote.env /tmp/vuz-bridge-remote.env

    ok "Малинка очищена"
fi

# ============================================================
#  ОЧИСТКА ВНЕШНЕГО СЕРВЕРА
# ============================================================
if [[ "$PI_ONLY" -eq 0 ]]; then
    if [[ -z "${EXTERNAL_HOST:-}" || -z "${EXTERNAL_SSH_USER:-}" ]]; then
        warn "EXTERNAL_HOST / EXTERNAL_SSH_USER не заданы в config.env — пропускаем очистку внешнего сервера"
    else
        echo
        log "=== Очистка внешнего сервера ${EXTERNAL_HOST} ==="

        if ! ssh_remote "true" >/dev/null 2>&1; then
            warn "SSH к ${EXTERNAL_HOST} не работает — пропускаем. Убедись, что ключ на месте."
        else
            # Удалённый скрипт. Аккуратно: только то, что создал morozovka-bridge.
            ssh_remote "bash -s" <<REMOTE_CLEANUP
set +e

# 1. OpenVPN сервер
if systemctl list-unit-files 'openvpn-server@*.service' --no-legend 2>/dev/null | grep -q openvpn-server@; then
    echo "[remote] Останавливаем openvpn-server@*"
    systemctl disable --now openvpn-server@server 2>/dev/null || true
fi

rm -rf /etc/openvpn/server
rm -rf /etc/openvpn/easy-rsa

# 2. Nginx-конфиги morozovka-* и vuz-*
echo "[remote] Удаляем Nginx-конфиги morozovka-* и vuz-*"
rm -f /etc/nginx/sites-enabled/morozovka-*.conf  /etc/nginx/sites-available/morozovka-*.conf
rm -f /etc/nginx/sites-enabled/vuz-*.conf        /etc/nginx/sites-available/vuz-*.conf
rm -f /etc/nginx/stream.d/morozovka-*.conf
rm -f /etc/nginx/stream.d/vuz-*.conf

if command -v nginx >/dev/null 2>&1; then
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
fi

# 3. Файлы в /root
echo "[remote] Чистим /root от артефактов morozovka-bridge"
rm -f  /root/morozovka-bridge-remote.env /root/morozovka-bridge-remote-setup.sh
rm -f  /root/vuz-bridge-remote.env       /root/vuz-bridge-remote-setup.sh
rm -rf /root/morozovka-bridge-client
rm -rf /root/vuz-bridge-client

# 4. sysctl
rm -f /etc/sysctl.d/99-morozovka-bridge.conf /etc/sysctl.d/99-vuz-bridge.conf

# 5. iptables: снимаем только наши правила (VPN-подсеть + tun0/eth0)
echo "[remote] Снимаем iptables-правила для ${VPN_NETWORK}/24"

# MASQUERADE
while iptables -t nat -C POSTROUTING -s "${VPN_NETWORK}/24" -o eth0 -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s "${VPN_NETWORK}/24" -o eth0 -j MASQUERADE
done

# FORWARD tun0 → eth0
while iptables -C FORWARD -i tun0 -o eth0 -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -i tun0 -o eth0 -j ACCEPT
done

# FORWARD eth0 → tun0
while iptables -C FORWARD -i eth0 -o tun0 -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -i eth0 -o tun0 -j ACCEPT
done

# Сохраняем, если есть netfilter-persistent
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save 2>/dev/null || true
fi

echo "[remote] Готово"
REMOTE_CLEANUP

            ok "Внешний сервер очищен"
        fi
    fi
fi

echo
ok "============================================"
ok " Очистка завершена"
ok "============================================"
echo
warn "Пакеты (openvpn, nginx, socat) НЕ удалялись. Если нужно — удали вручную:"
echo "    # на Малинке"
echo "    sudo apt purge openvpn socat"
echo "    # на внешнем сервере"
echo "    sudo apt purge openvpn easy-rsa nginx socat"
echo
