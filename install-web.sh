#!/usr/bin/env bash
# ============================================================
#  morozovka-bridge — установка веб-морды на Raspberry Pi
#  Запускать на Малинке: sudo ./install-web.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
source scripts/lib.sh
require_root
load_config

WEB_DIR="$SCRIPT_DIR/web"
INSTALL_DIR="/opt/morozovka-bridge"

log "Установка пакетов"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    python3 python3-venv python3-pip python3-dev \
    build-essential libffi-dev \
    rsync netcat-openbsd curl openssl

log "Копирование проекта в $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rsync -a --delete \
    --exclude 'web/.venv' \
    --exclude '__pycache__' \
    --exclude 'config.env' \
    --exclude '*.db' \
    --exclude '.git' \
    "$SCRIPT_DIR/" "$INSTALL_DIR/"

# config.env — симлинк на источник истины (репо в $SCRIPT_DIR)
# -f заменяет файл, -n не идёт вглубь директории, если таковая была
ln -sfn "$SCRIPT_DIR/config.env" "$INSTALL_DIR/config.env"

# ---------- WEB_SECRET: убедиться, что он есть ДО старта сервиса ----------
if ! grep -q "^WEB_SECRET=" "$SCRIPT_DIR/config.env"; then
    log "Генерация WEB_SECRET"
    SECRET=$(openssl rand -hex 32)
    {
        echo ""
        echo "# --- Web UI (сгенерировано автоматически) ---"
        echo "WEB_HOST=127.0.0.1"
        echo "WEB_PORT=5000"
        echo "WEB_SECRET=$SECRET"
        echo "WEB_SESSION_MAX_AGE=604800"
    } >> "$SCRIPT_DIR/config.env"
    chmod 600 "$SCRIPT_DIR/config.env"
fi

# ---------- Виртуальное окружение ----------
log "Создание виртуального окружения"
rm -rf "$INSTALL_DIR/web/.venv"
python3 -m venv "$INSTALL_DIR/web/.venv"
"$INSTALL_DIR/web/.venv/bin/pip" install --upgrade pip >/dev/null
"$INSTALL_DIR/web/.venv/bin/pip" install -r "$INSTALL_DIR/web/requirements.txt"

# ---------- БД и импорт ----------
log "Инициализация БД"
cd "$INSTALL_DIR"
"$INSTALL_DIR/web/.venv/bin/python" -m web.manage init-db

log "Импорт сервисов из config.env"
"$INSTALL_DIR/web/.venv/bin/python" -m web.manage import || true

# ---------- systemd ----------
log "Установка systemd-юнита"
cp "$WEB_DIR/morozovka-web.service" /etc/systemd/system/morozovka-web.service
systemctl daemon-reload
systemctl enable morozovka-web
systemctl restart morozovka-web

sleep 2

if systemctl is-active --quiet morozovka-web; then
    ok "Веб-морда запущена на 127.0.0.1:5000"
else
    err "Служба не запустилась. Смотрите: journalctl -u morozovka-web -n 50"
    exit 1
fi

# ---------- Проверка healthz ----------
if curl -sf -m 5 http://127.0.0.1:5000/healthz >/dev/null; then
    ok "healthz отвечает"
else
    warn "healthz не отвечает — проверьте логи"
fi

echo
ok "============================================"
ok " Веб-морда установлена!"
ok "============================================"
echo
warn "Создайте администратора:"
echo "    cd $INSTALL_DIR"
echo "    ./web/.venv/bin/python -m web.manage create-admin admin"
echo
warn "Затем добавьте в config.env сервис morozovka-web, чтобы открыть морду снаружи:"
echo '    "morozovka-web|_|127.0.0.1|5000|8090|http|8090"'
echo
warn "И примените:"
echo "    sudo ./scripts/add-service.sh"
echo
warn "Не забудьте на внешнем сервере:"
echo "    ufw allow 8090/tcp"
echo
