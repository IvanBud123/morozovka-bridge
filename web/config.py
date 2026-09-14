"""Загрузка config.env из корня проекта."""
from __future__ import annotations
import os
import warnings
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONFIG_ENV = PROJECT_ROOT / "config.env"
WEB_DIR = Path(__file__).resolve().parent


def _parse_env_file(path: Path) -> dict[str, str]:
    """Парсит bash-подобный config.env. Массивы игнорирует."""
    env: dict[str, str] = {}
    if not path.exists():
        return env
    with path.open() as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if line.startswith("SERVICES="):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            env[key] = value
    return env


ENV: dict[str, str] = _parse_env_file(CONFIG_ENV)


def get(key: str, default: str = "") -> str:
    return ENV.get(key, default)


def refresh() -> None:
    """Перечитать config.env (после изменений через веб-морду)."""
    global ENV
    ENV = _parse_env_file(CONFIG_ENV)


# --- Удобные алиасы ---
EXTERNAL_HOST = get("EXTERNAL_HOST")
EXTERNAL_SSH_PORT = get("EXTERNAL_SSH_PORT", "22")
EXTERNAL_SSH_USER = get("EXTERNAL_SSH_USER", "root")
PI_VPN_IP = get("PI_VPN_IP", "10.8.0.2")
PI_LAN_IP = get("PI_LAN_IP", "192.168.50.1")
PI_LAN_INTERFACE = get("PI_LAN_INTERFACE", "eth0")

# --- Веб-приложение ---
WEB_HOST = get("WEB_HOST", "127.0.0.1")
WEB_PORT = int(get("WEB_PORT", "5000"))

# WEB_SECRET: если не задан — предупреждаем и используем фиксированный
# небезопасный дефолт (иначе сессии слетали бы при каждом рестарте).
_web_secret = get("WEB_SECRET", "") or os.environ.get("WEB_SECRET", "")
if not _web_secret:
    warnings.warn(
        "WEB_SECRET не задан в config.env. Сессии небезопасны. "
        "Сгенерируйте: openssl rand -hex 32 и добавьте строку WEB_SECRET=... в config.env",
        stacklevel=2,
    )
    _web_secret = "INSECURE-DEFAULT-DO-NOT-USE-IN-PRODUCTION"
WEB_SECRET = _web_secret

WEB_DB_PATH = Path(get("WEB_DB_PATH", str(WEB_DIR / "morozovka.db")))
WEB_SESSION_MAX_AGE = int(get("WEB_SESSION_MAX_AGE", str(60 * 60 * 24 * 7)))
