#!/usr/bin/env bash
# Общие функции для всех скриптов morozovka-bridge.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Запустите от root: sudo $0"
}

load_config() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local cfg="$root/config.env"
    [[ -f "$cfg" ]] || die "Файл $cfg не найден. Скопируйте config.env.example → config.env"
    # shellcheck disable=SC1090
    source "$cfg"

    local required=(
        EXTERNAL_HOST EXTERNAL_SSH_USER
        VPN_PORT VPN_PROTO VPN_NETWORK VPN_NETMASK
        EXTERNAL_VPN_IP PI_VPN_IP PI_LAN_IP PI_LAN_INTERFACE
    )
    for v in "${required[@]}"; do
        [[ -n "${!v:-}" ]] || die "Переменная $v не задана в config.env"
    done
    [[ ${#SERVICES[@]} -gt 0 ]] || die "Массив SERVICES пуст"
}

validate_services() {
    local idx=0
    for entry in "${SERVICES[@]}"; do
        idx=$((idx+1))
        IFS='|' read -r name domain internal_ip internal_port vpn_port type external_port <<< "$entry"
        [[ -n "$name" && -n "$internal_ip" && -n "$internal_port" && -n "$vpn_port" && -n "$type" && -n "$external_port" ]] \
            || die "SERVICES[$idx]: не все поля заполнены → '$entry'"
        [[ "$type" =~ ^(http|tcp)$ ]] || die "SERVICES[$idx]: тип должен быть http или tcp → '$type'"
        [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || die "SERVICES[$idx]: имя только из [a-zA-Z0-9_-] → '$name'"
    done
}

# ---------- SSH ----------
SSH_COMMON_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/root/.ssh/known_hosts
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -T
)

# Работает после установки ключа. Пароль не спрашивает — если ключа нет,
# просто падает. Все команды идут через bash -c, потому что на внешнем
# сервере у root может быть fish/zsh.
ssh_remote() {
    ssh "${SSH_COMMON_OPTS[@]}" -o BatchMode=yes -p "${EXTERNAL_SSH_PORT}" \
        "${EXTERNAL_SSH_USER}@${EXTERNAL_HOST}" \
        bash -c "$*"
}

# Используется ТОЛЬКО во время первичной установки ключа.
# Пароль может спросить интерактивно.
ssh_remote_password() {
    ssh "${SSH_COMMON_OPTS[@]}" -p "${EXTERNAL_SSH_PORT}" \
        "${EXTERNAL_SSH_USER}@${EXTERNAL_HOST}" \
        bash -c "$*"
}

scp_to_remote() {
    scp "${SSH_COMMON_OPTS[@]}" -o BatchMode=yes -P "${EXTERNAL_SSH_PORT}" "$1" \
        "${EXTERNAL_SSH_USER}@${EXTERNAL_HOST}:$2"
}

scp_from_remote() {
    scp "${SSH_COMMON_OPTS[@]}" -o BatchMode=yes -P "${EXTERNAL_SSH_PORT}" \
        "${EXTERNAL_SSH_USER}@${EXTERNAL_HOST}:$1" "$2"
}
