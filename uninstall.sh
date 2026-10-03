#!/usr/bin/env bash
# ============================================================
#  morozovka-bridge — полное удаление
#
#  Делает то же, что scripts/cleanup.sh, и вдобавок может
#  удалить саму директорию проекта.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
source scripts/lib.sh
require_root

warn "Это вызовет scripts/cleanup.sh, а затем спросит про удаление папки проекта."
read -rp "Продолжить? (yes/no): " ans
[[ "$ans" == "yes" ]] || { echo "Отменено."; exit 0; }

# ---------- Шаг 1: очистка состояния ----------
bash scripts/cleanup.sh --yes

# ---------- Шаг 2: папка проекта ----------
echo
warn "Удалить саму папку проекта: $SCRIPT_DIR ?"
warn "(внутри может лежать config.env с паролями — сохрани, если нужно)"
read -rp "Удалить? (yes/no): " ans2
if [[ "$ans2" == "yes" ]]; then
    if [[ -f "$SCRIPT_DIR/config.env" ]]; then
        read -rp "Сделать бэкап config.env в /root/? (yes/no): " ans3
        if [[ "$ans3" == "yes" ]]; then
            cp "$SCRIPT_DIR/config.env" "/root/morozovka-bridge-config.env.bak.$(date +%s)"
            ok "Бэкап: /root/morozovka-bridge-config.env.bak.*"
        fi
    fi
    cd /
    rm -rf "$SCRIPT_DIR"
    ok "Папка проекта удалена"
else
    ok "Папка проекта сохранена: $SCRIPT_DIR"
fi

echo
ok "Удаление завершено."
