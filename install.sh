#!/usr/bin/env bash
# Установка bridge-webui на Малинку.
# Запускать от root: sudo ./install.sh
set -euo pipefail

INSTALL_DIR=/opt/bridge-webui
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "Запусти от root: sudo $0"
    exit 1
fi

echo "[*] Установка пакетов"
apt update -qq
apt install -y -qq python3 python3-venv python3-pip rsync openssl

echo "[*] Копирование в $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rsync -a --delete \
    --exclude 'venv' \
    --exclude '__pycache__' \
    "$SRC_DIR/" "$INSTALL_DIR/"

echo "[*] Виртуальное окружение"
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip >/dev/null
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

echo "[*] Настройка окружения"
if [[ ! -f /etc/bridge-webui.env ]]; then
    PASS=$(openssl rand -hex 8)
    cat > /etc/bridge-webui.env <<EOF
WEB_PASSWORD=$PASS
EOF
    chmod 600 /etc/bridge-webui.env
    echo
    echo "  ⚠️  Сгенерирован пароль: $PASS"
    echo "      Он сохранён в /etc/bridge-webui.env"
    echo "      Логин — любой (например, admin)."
    echo
fi

echo "[*] systemd unit"
cp "$INSTALL_DIR/bridge-webui.service" /etc/systemd/system/bridge-webui.service
systemctl daemon-reload
systemctl enable --now bridge-webui

sleep 2

if systemctl is-active --quiet bridge-webui; then
    echo
    echo "[+] Web UI запущен:"
    echo "    http://$(hostname -I | awk '{print $1}'):8080/"
    echo
    echo "    Пароль: cat /etc/bridge-webui.env"
    echo
else
    echo "[x] Не запустилось. Смотри: journalctl -u bridge-webui -n 30"
    exit 1
fi
