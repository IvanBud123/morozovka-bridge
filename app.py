#!/usr/bin/env python3
"""bridge-webui — веб-интерфейс управления мостами morozovka-bridge.

Совместим с Python 3.8+ (Ubuntu 20.04 на Raspberry Pi).
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from functools import wraps
from threading import Lock

from flask import Flask, Response, jsonify, render_template, request

app = Flask(__name__)

# ─────────────────────────── CONFIG ───────────────────────────
PI_VPN_IP         = os.environ.get("PI_VPN_IP", "10.8.0.2")
EXTERNAL_HOST     = os.environ.get("EXTERNAL_HOST", "31.128.43.79")
EXTERNAL_SSH_PORT = os.environ.get("EXTERNAL_SSH_PORT", "22")
EXTERNAL_SSH_USER = os.environ.get("EXTERNAL_SSH_USER", "root")
SSH_KEY           = os.environ.get("SSH_KEY", "/root/.ssh/id_ed25519")
WEB_PASSWORD      = os.environ.get("WEB_PASSWORD", "")
SERVICE_PREFIX    = "socat-"

# Мосты, обслуживаемые самим bridge-webui
VIRTUAL_BRIDGES = {
    8080: {"name": "bridge-webui", "dest": "127.0.0.1:8080"},
}

# Хосты для мониторинга
MONITOR_HOSTS = [
    {"name": "morozovka-rpi",   "host": "localhost",     "role": "шлюз",       "local": True},
    {"name": "morozovka-super", "host": "192.168.50.2",  "role": "сервер",     "local": False},
    {"name": "morozovka",       "host": "192.168.50.3",  "role": "сервер",     "local": False},
    {"name": "ws-1",            "host": "192.168.50.4",  "role": "станция",    "local": False},
    {"name": "ws-2",            "host": "192.168.50.5",  "role": "станция",    "local": False},
    {"name": "ws-3",            "host": "192.168.50.6",  "role": "станция",    "local": False},
    {"name": "ws-4",            "host": "192.168.50.7",  "role": "станция",    "local": False},
    {"name": "external",        "host": "10.8.0.1",      "role": "внешний",    "local": False},
]

COLLECTOR_PATH = "/opt/bridge-webui/collector.sh"
METRICS_CACHE_TTL = 4

HISTORY_MAX = 1080  # ~6 часов при сборе раз в 20 сек

_metrics_cache = {}
_metrics_lock = Lock()

_history = {}          # {host: {ts: deque, cpu: deque, ...}}
_history_lock = Lock()


# ─────────────────────────── HELPERS ──────────────────────────
def strip_prefix(s, prefix):
    if s.startswith(prefix):
        return s[len(prefix):]
    return s


def strip_suffix(s, suffix):
    if s.endswith(suffix):
        return s[:-len(suffix)]
    return s


def run(cmd, timeout=15):
    return subprocess.run(
        cmd, shell=True, capture_output=True, text=True, timeout=timeout,
    )


def ssh_run(remote_cmd, timeout=20):
    cmd = [
        "ssh",
        "-i", SSH_KEY,
        "-p", EXTERNAL_SSH_PORT,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "{}@{}".format(EXTERNAL_SSH_USER, EXTERNAL_HOST),
        remote_cmd,
    ]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def ssh_generic(host, remote_cmd, timeout=20):
    cmd = [
        "ssh",
        "-i", SSH_KEY,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "root@{}".format(host),
        remote_cmd,
    ]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def require_auth(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not WEB_PASSWORD:
            return f(*args, **kwargs)
        auth = request.authorization
        if not auth or auth.password != WEB_PASSWORD:
            return Response(
                "Требуется авторизация", 401,
                {"WWW-Authenticate": 'Basic realm="bridge-webui"'},
            )
        return f(*args, **kwargs)
    return wrapper


# ─────────────────────────── METRICS ──────────────────────────
def collect_one(host_conf):
    name = host_conf["name"]
    addr = host_conf["host"]

    with _metrics_lock:
        cached = _metrics_cache.get(name)
        if cached and (time.time() - cached["ts"]) < METRICS_CACHE_TTL:
            return cached["data"]

    result = {
        "name":  name,
        "host":  addr,
        "role":  host_conf.get("role", ""),
        "ok":    False,
        "error": None,
    }

    try:
        if host_conf.get("local"):
            r = subprocess.run(
                ["bash", COLLECTOR_PATH],
                capture_output=True, text=True, timeout=10,
            )
        else:
            with open(COLLECTOR_PATH) as f:
                script = f.read()
            r = subprocess.run(
                ["ssh", "-i", SSH_KEY,
                 "-o", "StrictHostKeyChecking=accept-new",
                 "-o", "BatchMode=yes",
                 "-o", "ConnectTimeout=5",
                 "root@{}".format(addr), "bash -s"],
                input=script, capture_output=True, text=True, timeout=15,
            )

        if r.returncode != 0:
            result["error"] = (r.stderr or "ssh failed").strip().split("\n")[-1][:200]
        else:
            line = r.stdout.strip().split("\n")[-1]
            data = json.loads(line)
            result.update(data)
            result["ok"] = True
    except subprocess.TimeoutExpired:
        result["error"] = "timeout"
    except json.JSONDecodeError as e:
        result["error"] = "json parse error: {}".format(str(e)[:120])
    except Exception as e:
        result["error"] = str(e)[:200]

    with _metrics_lock:
        _metrics_cache[name] = {"ts": time.time(), "data": result}
    return result


def collect_all():
    results = []
    with ThreadPoolExecutor(max_workers=len(MONITOR_HOSTS)) as pool:
        futures = {pool.submit(collect_one, h): h for h in MONITOR_HOSTS}
        for fut in as_completed(futures):
            results.append(fut.result())

    order = {h["name"]: i for i, h in enumerate(MONITOR_HOSTS)}
    results.sort(key=lambda r: order.get(r["name"], 999))
    return results


# ─────────────────────────── HISTORY ──────────────────────────
def _append_history(name, data):
    with _history_lock:
        h = _history.get(name)
        if h is None:
            h = {
                "ts":     deque(maxlen=HISTORY_MAX),
                "cpu":    deque(maxlen=HISTORY_MAX),
                "mem":    deque(maxlen=HISTORY_MAX),
                "net_rx": deque(maxlen=HISTORY_MAX),
                "net_tx": deque(maxlen=HISTORY_MAX),
                "load1":  deque(maxlen=HISTORY_MAX),
                "temp":   deque(maxlen=HISTORY_MAX),
            }
            _history[name] = h
        h["ts"].append(int(time.time()))
        h["cpu"].append(float(data.get("cpu_pct") or 0))
        h["mem"].append(float(data.get("mem_pct") or 0))
        h["net_rx"].append(int(data.get("net_rx") or 0))
        h["net_tx"].append(int(data.get("net_tx") or 0))
        try:
            l1 = float((data.get("load") or "0 0 0").split()[0])
        except (ValueError, IndexError):
            l1 = 0.0
        h["load1"].append(l1)
        h["temp"].append(int(data.get("temp_c") or 0))


def _background_collector():
    time.sleep(3)
    while True:
        try:
            for h in collect_all():
                if h.get("ok"):
                    _append_history(h["name"], h)
        except Exception:
            pass
        time.sleep(20)


# ─────────────────────────── BRIDGE STATE ─────────────────────
def get_pi_bridges():
    r = run("systemctl list-unit-files 'socat-*.service' --no-legend")
    bridges = {}

    for line in r.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        unit = parts[0]
        name = strip_suffix(strip_prefix(unit, SERVICE_PREFIX), ".service")

        show = run("systemctl show -p ExecStart --value {}".format(shlex.quote(unit)))
        s = show.stdout
        m_bind = re.search(r"TCP-LISTEN:(\d+)", s)
        m_dest = re.search(r"TCP:([\d.]+):(\d+)", s)
        if not m_bind or not m_dest:
            continue

        active = run("systemctl is-active {}".format(shlex.quote(unit))).stdout.strip()

        vpn_port = int(m_bind.group(1))
        bridges[vpn_port] = {
            "name":      name,
            "unit":      unit,
            "vpn_port":  vpn_port,
            "dest_ip":   m_dest.group(1),
            "dest_port": int(m_dest.group(2)),
            "pi_active": active == "active",
        }
    return bridges


def get_ext_bridges():
    r = ssh_run("iptables -t nat -S PREROUTING 2>/dev/null")
    bridges = {}

    for line in r.stdout.splitlines():
        if "DNAT" not in line or "--to-destination" not in line:
            continue
        m_port = re.search(r"--dport\s+(\d+)", line)
        m_dest = re.search(r"--to-destination\s+([\d.]+):(\d+)", line)
        if not m_port or not m_dest:
            continue

        ext_port = int(m_port.group(1))
        vpn_ip   = m_dest.group(1)
        vpn_port = int(m_dest.group(2))
        bridges[vpn_port] = {
            "external_port": ext_port,
            "vpn_ip":        vpn_ip,
        }
    return bridges


def collect_bridge_state():
    pi  = get_pi_bridges()
    ext = get_ext_bridges()

    all_ports = sorted(set(pi.keys()) | set(ext.keys()) | set(VIRTUAL_BRIDGES.keys()))
    rows = []

    for vpn_port in all_ports:
        if vpn_port in VIRTUAL_BRIDGES and vpn_port not in pi:
            v = VIRTUAL_BRIDGES[vpn_port]
            d_ip, d_port = v["dest"].split(":")
            e = ext.get(vpn_port)
            rows.append({
                "name":          v["name"],
                "vpn_port":      vpn_port,
                "dest_ip":       d_ip,
                "dest_port":     int(d_port),
                "external_port": e["external_port"] if e else "—",
                "pi_active":     True,
                "pi_exists":     True,
                "ext_exists":    e is not None,
                "status":        "ok" if e else "missing-ext",
            })
            continue

        p = pi.get(vpn_port)
        e = ext.get(vpn_port)

        if p and e:
            status = "ok" if p["pi_active"] else "warn"
        elif p and not e:
            status = "missing-ext"
        else:
            status = "missing-pi"

        rows.append({
            "name":          p["name"] if p else "orphan-{}".format(vpn_port),
            "vpn_port":      vpn_port,
            "dest_ip":       p["dest_ip"] if p else "—",
            "dest_port":     p["dest_port"] if p else "—",
            "external_port": e["external_port"] if e else "—",
            "pi_active":     p["pi_active"] if p else False,
            "pi_exists":     p is not None,
            "ext_exists":    e is not None,
            "status":        status,
        })

    return rows


# ─────────────────────────── ROUTES ───────────────────────────
@app.route("/")
@require_auth
def index():
    return render_template("index.html")


@app.route("/metrics")
@require_auth
def metrics_page():
    return render_template("metrics.html")


@app.route("/host/<name>")
@require_auth
def host_page(name):
    return render_template("host.html", host_name=name)


@app.route("/api/state")
@require_auth
def api_state():
    try:
        return jsonify({
            "ok": True,
            "bridges": collect_bridge_state(),
            "external_host": EXTERNAL_HOST,
        })
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.route("/api/metrics")
@require_auth
def api_metrics():
    try:
        return jsonify({
            "ok": True,
            "ts": int(time.time() * 1000),
            "hosts": collect_all(),
        })
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


@app.route("/api/host/<name>")
@require_auth
def api_host(name):
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", name):
        return jsonify({"ok": False, "error": "bad name"}), 400
    for h in MONITOR_HOSTS:
        if h["name"] == name:
            return jsonify({"ok": True, "host": collect_one(h)})
    return jsonify({"ok": False, "error": "not found"}), 404


@app.route("/api/history/<name>")
@require_auth
def api_history(name):
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", name):
        return jsonify({"ok": False, "error": "bad name"}), 400

    with _history_lock:
        h = _history.get(name)
        if not h:
            empty = {"ts": [], "cpu": [], "mem": [], "net_rx": [],
                     "net_tx": [], "load1": [], "temp": []}
            return jsonify({"ok": True, "name": name, "history": empty})
        data = {k: list(v) for k, v in h.items()}

    return jsonify({"ok": True, "name": name, "history": data})


@app.route("/api/add", methods=["POST"])
@require_auth
def api_add():
    data = request.get_json() or {}

    name          = (data.get("name") or "").strip()
    dest_ip       = (data.get("dest_ip") or "").strip()
    dest_port     = int(data.get("dest_port") or 0)
    vpn_port      = int(data.get("vpn_port") or 0)
    external_port = int(data.get("external_port") or 0)

    if not re.fullmatch(r"[a-zA-Z0-9_-]+", name):
        return jsonify({"ok": False, "error": "Некорректное имя"}), 400
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", dest_ip):
        return jsonify({"ok": False, "error": "Некорректный IP"}), 400
    for port, label in [(dest_port, "dest_port"), (vpn_port, "vpn_port"),
                        (external_port, "external_port")]:
        if not (1 <= port <= 65535):
            return jsonify({"ok": False, "error": "Неверный {}".format(label)}), 400

    unit = "{}{}.service".format(SERVICE_PREFIX, name)
    unit_path = "/etc/systemd/system/{}".format(unit)

    if os.path.exists(unit_path):
        return jsonify({"ok": False,
                        "error": "Сервис {} уже существует".format(unit)}), 409

    r = run("ss -tlnp | grep ':{} ' || true".format(vpn_port))
    if r.stdout.strip():
        return jsonify({"ok": False,
                        "error": "Порт {} уже занят на Малинке".format(vpn_port)}), 409

    unit_content = """[Unit]
Description=socat forwarder (VPN:{vpn_port} -> {dest_ip}:{dest_port})
After=network-online.target openvpn-client@client.service
Wants=network-online.target
Requires=openvpn-client@client.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/fuser -k {vpn_port}/tcp
ExecStart=/usr/bin/socat -d -d TCP-LISTEN:{vpn_port},fork,reuseaddr,bind={pi_vpn_ip} TCP:{dest_ip}:{dest_port}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
""".format(
        vpn_port=vpn_port, dest_ip=dest_ip, dest_port=dest_port,
        pi_vpn_ip=PI_VPN_IP,
    )

    with open(unit_path, "w") as f:
        f.write(unit_content)

    run("systemctl daemon-reload")
    r = run("systemctl enable --now {}".format(shlex.quote(unit)))
    if r.returncode != 0:
        os.unlink(unit_path)
        run("systemctl daemon-reload")
        return jsonify({"ok": False,
                        "error": "socat не запустился: {}".format(r.stderr or r.stdout)}), 500

    ipt_cmds = (
        "iptables -t nat -C PREROUTING -p tcp --dport {ep} "
        "-j DNAT --to-destination {vip}:{vp} 2>/dev/null || "
        "iptables -t nat -A PREROUTING -p tcp --dport {ep} "
        "-j DNAT --to-destination {vip}:{vp}; "
        "iptables -C FORWARD -p tcp -d {vip} --dport {vp} "
        "-j ACCEPT 2>/dev/null || "
        "iptables -A FORWARD -p tcp -d {vip} --dport {vp} -j ACCEPT; "
        "iptables -C FORWARD -p tcp -s {vip} --sport {vp} "
        "-m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || "
        "iptables -A FORWARD -p tcp -s {vip} --sport {vp} "
        "-m state --state ESTABLISHED,RELATED -j ACCEPT; "
        "iptables -t nat -C POSTROUTING -o tun0 -p tcp --dport {vp} "
        "-j MASQUERADE 2>/dev/null || "
        "iptables -t nat -A POSTROUTING -o tun0 -p tcp --dport {vp} "
        "-j MASQUERADE; "
        "netfilter-persistent save >/dev/null 2>&1 || true"
    ).format(ep=external_port, vip=PI_VPN_IP, vp=vpn_port)

    r = ssh_run(ipt_cmds)
    if r.returncode != 0:
        run("systemctl disable --now {}".format(shlex.quote(unit)))
        os.unlink(unit_path)
        run("systemctl daemon-reload")
        return jsonify({"ok": False,
                        "error": "iptables не применились: {}".format(r.stderr or r.stdout)}), 500

    return jsonify({"ok": True, "message": "Мост {} добавлен".format(name)})


@app.route("/api/remove", methods=["POST"])
@require_auth
def api_remove():
    data = request.get_json() or {}
    name = (data.get("name") or "").strip()

    if not re.fullmatch(r"[a-zA-Z0-9_-]+", name):
        return jsonify({"ok": False, "error": "Некорректное имя"}), 400

    unit = "{}{}.service".format(SERVICE_PREFIX, name)
    unit_path = "/etc/systemd/system/{}".format(unit)

    pi = get_pi_bridges()
    ext = get_ext_bridges()

    target_vpn_port = None
    target_ext_port = None
    for vp, p in pi.items():
        if p["name"] == name:
            target_vpn_port = vp
            break

    if target_vpn_port is None:
        return jsonify({"ok": False,
                        "error": "Сервис {} не найден".format(name)}), 404

    if target_vpn_port in ext:
        target_ext_port = ext[target_vpn_port]["external_port"]

    if target_ext_port:
        ipt_cmds = (
            "while iptables -t nat -C PREROUTING -p tcp --dport {ep} "
            "-j DNAT --to-destination {vip}:{vp} 2>/dev/null; do "
            "iptables -t nat -D PREROUTING -p tcp --dport {ep} "
            "-j DNAT --to-destination {vip}:{vp}; done; "
            "while iptables -C FORWARD -p tcp -d {vip} "
            "--dport {vp} -j ACCEPT 2>/dev/null; do "
            "iptables -D FORWARD -p tcp -d {vip} "
            "--dport {vp} -j ACCEPT; done; "
            "while iptables -C FORWARD -p tcp -s {vip} "
            "--sport {vp} -m state --state ESTABLISHED,RELATED "
            "-j ACCEPT 2>/dev/null; do "
            "iptables -D FORWARD -p tcp -s {vip} "
            "--sport {vp} -m state --state ESTABLISHED,RELATED "
            "-j ACCEPT; done; "
            "while iptables -t nat -C POSTROUTING -o tun0 -p tcp "
            "--dport {vp} -j MASQUERADE 2>/dev/null; do "
            "iptables -t nat -D POSTROUTING -o tun0 -p tcp "
            "--dport {vp} -j MASQUERADE; done; "
            "netfilter-persistent save >/dev/null 2>&1 || true"
        ).format(ep=target_ext_port, vip=PI_VPN_IP, vp=target_vpn_port)
        ssh_run(ipt_cmds)

    run("systemctl disable --now {} 2>/dev/null || true".format(shlex.quote(unit)))
    if os.path.exists(unit_path):
        os.unlink(unit_path)
    run("systemctl daemon-reload")

    return jsonify({"ok": True, "message": "Мост {} удалён".format(name)})


@app.route("/api/test/<name>", methods=["POST"])
@require_auth
def api_test(name):
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", name):
        return jsonify({"ok": False, "error": "Некорректное имя"}), 400

    pi = get_pi_bridges()
    ext = get_ext_bridges()

    vpn_port = None
    for vp, p in pi.items():
        if p["name"] == name:
            vpn_port = vp
            break

    is_virtual = False
    if vpn_port is None:
        for vp, v in VIRTUAL_BRIDGES.items():
            if v["name"] == name:
                vpn_port = vp
                is_virtual = True
                break

    if vpn_port is None:
        return jsonify({"ok": False, "error": "Сервис не найден"}), 404

    checks = []

    if is_virtual:
        v = VIRTUAL_BRIDGES[vpn_port]
        d_ip, d_port = v["dest"].split(":")
        checks.append({"name": "bridge-webui на Малинке", "ok": True,
                       "detail": "обслуживается самим Flask"})
        r = run("ss -tlnp | grep ':{} ' || true".format(vpn_port))
        listening = bool(r.stdout.strip())
        checks.append({"name": "Порт {} на Малинке".format(vpn_port),
                       "ok": listening,
                       "detail": r.stdout.strip().split()[-1] if listening else "не слушается"})
        r = run("nc -zv -w2 {} {} 2>&1 || true".format(d_ip, d_port))
        dst_ok = "succeeded" in r.stdout or "open" in r.stdout
        checks.append({"name": "Доступ к {}:{}".format(d_ip, d_port),
                       "ok": dst_ok,
                       "detail": r.stdout.strip().split("\n")[-1][:80] if r.stdout else ""})
        ext_ok = vpn_port in ext
        checks.append({"name": "DNAT на внешнем", "ok": ext_ok,
                       "detail": "порт {}".format(ext[vpn_port]["external_port"]) if ext_ok else "нет правила"})
        r = ssh_run("nc -zv -w3 {} {} 2>&1 || true".format(PI_VPN_IP, vpn_port))
        ssh_ok = "succeeded" in r.stdout or "open" in r.stdout
        checks.append({"name": "Внешний → {}:{}".format(PI_VPN_IP, vpn_port),
                       "ok": ssh_ok,
                       "detail": r.stdout.strip().split("\n")[-1][:80] if r.stdout else ""})
        return jsonify({"ok": all(c["ok"] for c in checks), "checks": checks})

    active = pi[vpn_port]["pi_active"]
    checks.append({"name": "socat на Малинке", "ok": active,
                   "detail": "активен" if active else "не активен"})

    r = run("ss -tlnp | grep ':{} ' || true".format(vpn_port))
    listening = bool(r.stdout.strip())
    checks.append({"name": "Порт {} на Малинке".format(vpn_port),
                   "ok": listening,
                   "detail": r.stdout.strip().split()[-1] if listening else "не слушается"})

    dest_ip = pi[vpn_port]["dest_ip"]
    dest_port = pi[vpn_port]["dest_port"]
    r = run("nc -zv -w2 {} {} 2>&1 || true".format(dest_ip, dest_port))
    dst_ok = "succeeded" in r.stdout or "open" in r.stdout
    checks.append({"name": "Доступ к {}:{}".format(dest_ip, dest_port),
                   "ok": dst_ok,
                   "detail": r.stdout.strip().split("\n")[-1][:80] if r.stdout else ""})

    ext_ok = vpn_port in ext
    checks.append({"name": "DNAT на внешнем", "ok": ext_ok,
                   "detail": "порт {}".format(ext[vpn_port]["external_port"]) if ext_ok else "нет правила"})

    r = ssh_run("nc -zv -w3 {} {} 2>&1 || true".format(PI_VPN_IP, vpn_port))
    ssh_ok = "succeeded" in r.stdout or "open" in r.stdout
    checks.append({"name": "Внешний → {}:{}".format(PI_VPN_IP, vpn_port),
                   "ok": ssh_ok,
                   "detail": r.stdout.strip().split("\n")[-1][:80] if r.stdout else ""})

    return jsonify({"ok": all(c["ok"] for c in checks), "checks": checks})


if __name__ == "__main__":
    # Фоновый сбор истории метрик
    threading.Thread(target=_background_collector, daemon=True).start()

    host = os.environ.get("WEB_HOST", "0.0.0.0")
    port = int(os.environ.get("WEB_PORT", "8080"))
    app.run(host=host, port=port, debug=False)
