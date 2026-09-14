"""Синхронизация сервисов из БД в config.env и обратно."""
from __future__ import annotations
import re
from sqlmodel import Session, select

from . import config
from .db import engine
from .models import Service

CONFIG_ENV = config.CONFIG_ENV
SERVICES_START = "SERVICES=("
SERVICES_END = ")"


def _escape(v: str) -> str:
    """Экранирует значение для bash-массива."""
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`").replace("$", "\\$")


def services_to_lines(services: list[Service]) -> list[str]:
    """Возвращает строки для массива SERVICES."""
    lines: list[str] = []
    for s in services:
        if not s.enabled:
            continue
        fields = [
            s.name,
            s.domain or "_",
            s.internal_ip,
            str(s.internal_port),
            str(s.vpn_port),
            s.type,
            str(s.external_port),
        ]
        line = "|".join(fields)
        lines.append(f'  "{_escape(line)}"')
    return lines


def rebuild_config_env() -> None:
    """Перегенерирует блок SERVICES в config.env, не трогая остальное."""
    if not CONFIG_ENV.exists():
        raise FileNotFoundError(f"{CONFIG_ENV} не найден")

    with Session(engine) as s:
        services = s.exec(select(Service).order_by(Service.name)).all()

    original = CONFIG_ENV.read_text(encoding="utf-8").splitlines()

    start_idx = None
    end_idx = None
    for i, line in enumerate(original):
        if line.strip().startswith(SERVICES_START):
            start_idx = i
        if start_idx is not None and line.strip() == SERVICES_END and i > start_idx:
            end_idx = i
            break

    new_block = [SERVICES_START, *services_to_lines(services), SERVICES_END]

    if start_idx is not None and end_idx is not None:
        result = original[:start_idx] + new_block + original[end_idx + 1:]
    else:
        result = original + ["", "# Автоматически сгенерировано morozovka-bridge", *new_block]

    CONFIG_ENV.write_text("\n".join(result) + "\n", encoding="utf-8")


def import_from_config_env() -> int:
    """Парсит SERVICES из config.env и создаёт записи в БД. Возвращает кол-во импортированных."""
    from .db import init_db

    init_db()
    if not CONFIG_ENV.exists():
        return 0

    text = CONFIG_ENV.read_text(encoding="utf-8")
    m = re.search(r"SERVICES=\(\s*\n(.*?)\n\)", text, re.DOTALL)
    if not m:
        return 0

    block = m.group(1)
    entries: list[str] = []
    for line in block.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        line = line.strip('"').strip("'")
        line = line.replace('\\"', '"').replace("\\$", "$").replace("\\`", "`").replace("\\\\", "\\")
        entries.append(line)

    count = 0
    with Session(engine) as s:
        existing = {svc.name for svc in s.exec(select(Service)).all()}
        for entry in entries:
            parts = entry.split("|")
            if len(parts) != 7:
                continue
            name, domain, ip, iport, vport, stype, eport = parts
            if name in existing:
                continue
            s.add(Service(
                name=name, domain=domain or "_",
                internal_ip=ip, internal_port=int(iport),
                vpn_port=int(vport), type=stype,
                external_port=int(eport),
            ))
            count += 1
        s.commit()
    return count
