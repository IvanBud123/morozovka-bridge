"""Тестирование цепочки для сервиса."""
from __future__ import annotations
import asyncio
import shlex
from dataclasses import dataclass, asdict
from typing import Any

from . import config
from .models import Service


@dataclass
class Step:
    name: str
    ok: bool
    detail: str = ""
    hint: str = ""
    duration_ms: int = 0


async def _run(cmd: str, timeout: float = 10.0) -> tuple[int, str, int]:
    """Возвращает (returncode, output, elapsed_ms)."""
    loop = asyncio.get_running_loop()
    start = loop.time()
    try:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
    except Exception as e:
        return -1, f"spawn error: {e}", 0
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        elapsed = int((loop.time() - start) * 1000)
        return proc.returncode or 0, out.decode(errors="replace").strip(), elapsed
    except asyncio.TimeoutError:
        try:
            proc.kill()
        except Exception:
            pass
        elapsed = int((loop.time() - start) * 1000)
        return -1, "timeout", elapsed


async def _ssh_remote(cmd: str, timeout: float = 15.0) -> tuple[int, str, int]:
    port = config.EXTERNAL_SSH_PORT
    user = config.EXTERNAL_SSH_USER
    host = config.EXTERNAL_HOST
    quoted = shlex.quote(cmd)
    full = (
        f"ssh -o StrictHostKeyChecking=accept-new "
        f"-o ConnectTimeout=5 -p {port} "
        f"{shlex.quote(user)}@{shlex.quote(host)} {quoted}"
    )
    return await _run(full, timeout=timeout)


def _last_line(s: str) -> str:
    lines = [l for l in s.splitlines() if l.strip()]
    return lines[-1] if lines else ""


async def test_service(service: Service) -> dict[str, Any]:
    """Прогоняет всю цепочку и возвращает отчёт."""
    steps: list[Step] = []
    ext_host = config.EXTERNAL_HOST

    # 1. VPN-туннель
    rc, out, ms = await _run("ip -o link show tun0")
    steps.append(Step(
        name="VPN-туннель (tun0) на Малинке",
        ok=(rc == 0),
        detail=_last_line(out) if rc == 0 else (out or "нет tun0"),
        hint="OpenVPN клиент не поднял интерфейс. Проверьте `journalctl -u openvpn-client@client -f`.",
        duration_ms=ms,
    ))

    # 2. socat
    rc, out, ms = await _run(f"systemctl is-active socat@{shlex.quote(service.name)}")
    steps.append(Step(
        name=f"Служба socat@{service.name}",
        ok=(out.strip() == "active"),
        detail=out.strip() or "(пусто)",
        hint="sudo systemctl status socat@<имя> на Малинке",
        duration_ms=ms,
    ))

    # 3. Ping внутреннего хоста
    rc, out, ms = await _run(f"ping -c1 -W2 {shlex.quote(service.internal_ip)}")
    ping_ok = (rc == 0) and ("1 received" in out or "1 packets received" in out)
    steps.append(Step(
        name=f"Ping до {service.internal_ip}",
        ok=ping_ok,
        detail=_last_line(out) if out else "",
        hint="Внутренний сервер недоступен по локальной сети.",
        duration_ms=ms,
    ))

    # 4. TCP-порт на внутреннем хосте
    rc, out, ms = await _run(
        f"nc -zv -w2 {shlex.quote(service.internal_ip)} {service.internal_port}"
    )
    steps.append(Step(
        name=f"Порт {service.internal_port} на {service.internal_ip}",
        ok=(rc == 0),
        detail=_last_line(out),
        hint="Сервис не слушает порт, или firewall на внутреннем сервере.",
        duration_ms=ms,
    ))

    # 5. Nginx на внешнем сервере
    rc, out, ms = await _ssh_remote("nginx -t 2>&1")
    nginx_ok = "syntax is ok" in out and "test is successful" in out
    steps.append(Step(
        name="Nginx на внешнем сервере",
        ok=nginx_ok,
        detail=_last_line(out),
        hint="nginx -t на внешнем сервере.",
        duration_ms=ms,
    ))

    # 6. Внешний порт открыт
    rc, out, ms = await _run(
        f"nc -zv -w3 {shlex.quote(ext_host)} {service.external_port}", timeout=10
    )
    steps.append(Step(
        name=f"Внешний порт {service.external_port} на {ext_host}",
        ok=(rc == 0),
        detail=_last_line(out),
        hint="Firewall на внешнем сервере, либо Nginx не слушает порт.",
        duration_ms=ms,
    ))

    # 7. HTTP-ответ (только для http)
    if service.type == "http":
        rc, out, ms = await _run(
            f"curl -s -o /dev/null -w '%{{http_code}}' -m 5 "
            f"http://{shlex.quote(ext_host)}:{service.external_port}/",
            timeout=10,
        )
        code_ok = rc == 0 and out.isdigit() and int(out) < 500
        steps.append(Step(
            name="HTTP-ответ",
            ok=code_ok,
            detail=f"HTTP {out}",
            hint="5xx — ошибка upstream. 4xx — сервис жив, но требует авторизации.",
            duration_ms=ms,
        ))

    all_ok = all(s.ok for s in steps)
    return {
        "overall": "ok" if all_ok else "fail",
        "steps": [asdict(s) for s in steps],
    }
