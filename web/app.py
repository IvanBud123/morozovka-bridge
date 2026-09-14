"""Morozovka-Bridge Web UI — FastAPI."""
from __future__ import annotations
import asyncio
import json
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlmodel import Session, select

from . import config, auth, config_manager, chain_test
from .db import engine, init_db
from .models import User, Service, TestRun

WEB_DIR = Path(__file__).resolve().parent


@asynccontextmanager
async def lifespan(_app: FastAPI):
    init_db()
    yield


app = FastAPI(title="morozovka-bridge", docs_url=None, redoc_url=None, lifespan=lifespan)
app.mount("/static", StaticFiles(directory=WEB_DIR / "static"), name="static")
templates = Jinja2Templates(directory=str(WEB_DIR / "templates"))


# ---------------------------------------------------------------- middleware
@app.middleware("http")
async def attach_user(request: Request, call_next):
    request.state.user = None
    token = request.cookies.get(auth.COOKIE_NAME)
    if token:
        uid = auth.read_session_token(token)
        if uid:
            request.state.user = auth.get_user_by_id(uid)
    return await call_next(request)


# ---------------------------------------------------------------- helpers
def _render(request: Request, name: str, **kw):
    ctx = {"request": request, "user": request.state.user, "now": datetime.utcnow()}
    ctx.update(kw)
    return templates.TemplateResponse(name, ctx)


def _check_tun() -> bool:
    import subprocess
    try:
        return subprocess.run(
            ["ip", "link", "show", "tun0"],
            capture_output=True, timeout=3,
        ).returncode == 0
    except Exception:
        return False


# ================================================================= PAGES
@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request):
    if not request.state.user:
        return RedirectResponse("/login", status_code=303)

    with Session(engine) as s:
        services = s.exec(select(Service).order_by(Service.name)).all()
        last_tests: dict[int, TestRun] = {}
        for svc in services:
            run = s.exec(
                select(TestRun)
                .where(TestRun.service_id == svc.id)
                .order_by(TestRun.id.desc())
                .limit(1)
            ).first()
            if run:
                last_tests[svc.id] = run

    return _render(
        request, "dashboard.html",
        services=services, last_tests=last_tests,
        external_host=config.EXTERNAL_HOST,
        vpn_ok=_check_tun(),
    )


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request, error: Optional[str] = None, next: Optional[str] = None):
    if request.state.user:
        return RedirectResponse("/", status_code=303)
    return _render(request, "login.html", error=error, next=next or "/")


@app.post("/login")
def login_submit(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    next: str = Form("/"),
):
    user = auth.get_user_by_username(username)
    if not user or not user.is_active or not auth.verify_password(password, user.password_hash):
        return _render(request, "login.html", error="Неверный логин или пароль", next=next)
    token = auth.create_session_token(user.id)
    resp = RedirectResponse(next or "/", status_code=303)
    resp.set_cookie(
        auth.COOKIE_NAME, token,
        max_age=config.WEB_SESSION_MAX_AGE,
        httponly=True, samesite="lax",
    )
    return resp


@app.get("/logout")
def logout():
    resp = RedirectResponse("/login", status_code=303)
    resp.delete_cookie(auth.COOKIE_NAME)
    return resp


# ---------------------------------------------------------------- services
@app.get("/services", response_class=HTMLResponse)
def services_page(request: Request):
    if not request.state.user:
        return RedirectResponse("/login", status_code=303)
    with Session(engine) as s:
        q = select(Service).order_by(Service.name)
        if not request.state.user.is_admin():
            q = q.where(
                (Service.owner_id == request.state.user.id) | (Service.owner_id.is_(None))
            )
        services = s.exec(q).all()
    return _render(request, "services.html", services=services)


@app.get("/services/new", response_class=HTMLResponse)
def service_new(request: Request):
    if not request.state.user:
        return RedirectResponse("/login", status_code=303)
    if request.state.user.role == "viewer":
        raise HTTPException(403)
    return _render(request, "service_form.html", service=None, error=None)


@app.post("/services/new")
def service_create(
    request: Request,
    name: str = Form(...),
    domain: str = Form("_"),
    internal_ip: str = Form(...),
    internal_port: int = Form(...),
    vpn_port: int = Form(...),
    type: str = Form("http"),
    external_port: int = Form(...),
    description: str = Form(""),
):
    if not request.state.user:
        return RedirectResponse("/login", status_code=303)
    if request.state.user.role == "viewer":
        raise HTTPException(403)

    new_id: Optional[int] = None
    with Session(engine) as s:
        if s.exec(select(Service).where(Service.name == name)).first():
            return _render(request, "service_form.html", service=None,
                           error=f"Сервис с именем {name} уже существует")
        svc = Service(
            name=name, domain=domain or "_",
            internal_ip=internal_ip, internal_port=internal_port,
            vpn_port=vpn_port, type=type, external_port=external_port,
            description=description or None,
            owner_id=request.state.user.id,
        )
        s.add(svc)
        s.commit()
        s.refresh(svc)
        new_id = svc.id
        try:
            config_manager.rebuild_config_env()
            _apply_services_sync()
        except Exception as e:
            return _render(request, "service_form.html", service=svc,
                           error=f"Сервис создан, но не удалось применить: {e}")
    return RedirectResponse(f"/services/{new_id}", status_code=303)


@app.get("/services/{sid}", response_class=HTMLResponse)
def service_detail(request: Request, sid: int):
    if not request.state.user:
        return RedirectResponse("/login", status_code=303)
    with Session(engine) as s:
        svc = s.get(Service, sid)
        if not svc:
            raise HTTPException(404)
        runs = s.exec(
            select(TestRun).where(TestRun.service_id == sid)
            .order_by(TestRun.id.desc()).limit(10)
        ).all()
        last_run = runs[0] if runs else None
        last_steps = json.loads(last_run.steps_json) if last_run else []
    return _render(request, "service_detail.html", service=svc,
                   runs=runs, last_run=last_run, last_steps=last_steps,
                   external_host=config.EXTERNAL_HOST)


@app.get("/services/{sid}/edit", response_class=HTMLResponse)
def service_edit(request: Request, sid: int):
    user = request.state.user
    if not user:
        return RedirectResponse("/login", status_code=303)
    with Session(engine) as s:
        svc = s.get(Service, sid)
        if not svc:
            raise HTTPException(404)
        if not user.can_edit(svc):
            raise HTTPException(403)
    return _render(request, "service_form.html", service=svc, error=None)


@app.post("/services/{sid}/edit")
def service_update(
    request: Request, sid: int,
    name: str = Form(...),
    domain: str = Form("_"),
    internal_ip: str = Form(...),
    internal_port: int = Form(...),
    vpn_port: int = Form(...),
    type: str = Form("http"),
    external_port: int = Form(...),
    description: str = Form(""),
):
    user = request.state.user
    if not user:
        return RedirectResponse("/login", status_code=303)
    with Session(engine) as s:
        svc = s.get(Service, sid)
        if not svc:
            raise HTTPException(404)
        if not user.can_edit(svc):
            raise HTTPException(403)

        # Проверка уникальности имени (если его поменяли)
        dup = s.exec(
            select(Service).where(Service.name == name, Service.id != sid)
        ).first()
        if dup:
            return _render(request, "service_form.html", service=svc,
                           error=f"Имя {name} уже занято другим сервисом")

        svc.name = name
        svc.domain = domain or "_"
        svc.internal_ip = internal_ip
        svc.internal_port = internal_port
        svc.vpn_port = vpn_port
        svc.type = type
        svc.external_port = external_port
        svc.description = description or None
        svc.updated_at = datetime.utcnow()
        s.add(svc)
        s.commit()

    try:
        config_manager.rebuild_config_env()
        _apply_services_sync()
    except Exception as e:
        raise HTTPException(500, f"Ошибка применения: {e}")
    return RedirectResponse(f"/services/{sid}", status_code=303)


@app.post("/services/{sid}/delete")
def service_delete(request: Request, sid: int):
    user = request.state.user
    if not user:
        return RedirectResponse("/login", status_code=303)
    with Session(engine) as s:
        svc = s.get(Service, sid)
        if not svc:
            raise HTTPException(404)
        if not user.can_edit(svc):
            raise HTTPException(403)
        s.delete(svc)
        s.commit()
    try:
        config_manager.rebuild_config_env()
        _apply_services_sync()
    except Exception:
        pass
    return RedirectResponse("/services", status_code=303)


# ---------------------------------------------------------------- tests (AJAX)
@app.post("/services/{sid}/test")
async def service_test(request: Request, sid: int):
    user = request.state.user
    if not user:
        raise HTTPException(401)
    with Session(engine) as s:
        svc = s.get(Service, sid)
        if not svc:
            raise HTTPException(404)
        service = Service(**svc.model_dump())

    result = await chain_test.test_service(service)

    with Session(engine) as s:
        run = TestRun(
            service_id=sid,
            finished_at=datetime.utcnow(),
            overall=result["overall"],
            steps_json=json.dumps(result["steps"], ensure_ascii=False),
            triggered_by=user.id,
        )
        s.add(run)
        s.commit()
        s.refresh(run)
        run_id = run.id

    return JSONResponse({
        "overall": result["overall"],
        "steps": result["steps"],
        "run_id": run_id,
    })


@app.post("/services/test-all")
async def services_test_all(request: Request):
    user = request.state.user
    if not user:
        raise HTTPException(401)
    with Session(engine) as s:
        services = s.exec(select(Service)).all()
        services = [Service(**svc.model_dump()) for svc in services]

    results = await asyncio.gather(*(chain_test.test_service(svc) for svc in services))

    with Session(engine) as s:
        for svc, res in zip(services, results):
            s.add(TestRun(
                service_id=svc.id,
                finished_at=datetime.utcnow(),
                overall=res["overall"],
                steps_json=json.dumps(res["steps"], ensure_ascii=False),
                triggered_by=user.id,
            ))
        s.commit()

    return JSONResponse({
        "results": [
            {"service_id": svc.id, "name": svc.name, **res}
            for svc, res in zip(services, results)
        ]
    })


# ---------------------------------------------------------------- users (admin)
@app.get("/users", response_class=HTMLResponse)
def users_page(request: Request):
    if not request.state.user:
        return RedirectResponse("/login", status_code=303)
    if not request.state.user.is_admin():
        raise HTTPException(403)
    with Session(engine) as s:
        users = s.exec(select(User).order_by(User.username)).all()
    return _render(request, "users.html", users=users)


@app.get("/users/new", response_class=HTMLResponse)
def user_new(request: Request):
    if not request.state.user or not request.state.user.is_admin():
        raise HTTPException(403)
    return _render(request, "user_form.html", target_user=None, error=None)


@app.post("/users/new")
def user_create(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    role: str = Form("viewer"),
    email: str = Form(""),
):
    if not request.state.user or not request.state.user.is_admin():
        raise HTTPException(403)
    if role not in ("admin", "operator", "viewer"):
        raise HTTPException(400, "Неверная роль")
    if len(password) < 6:
        return _render(request, "user_form.html", target_user=None,
                       error="Пароль минимум 6 символов")
    with Session(engine) as s:
        if s.exec(select(User).where(User.username == username)).first():
            return _render(request, "user_form.html", target_user=None,
                           error="Такой логин уже занят")
        u = User(username=username, password_hash=auth.hash_password(password),
                 role=role, email=email or None)
        s.add(u)
        s.commit()
    return RedirectResponse("/users", status_code=303)


@app.get("/users/{uid}/edit", response_class=HTMLResponse)
def user_edit(request: Request, uid: int):
    if not request.state.user or not request.state.user.is_admin():
        raise HTTPException(403)
    with Session(engine) as s:
        target = s.get(User, uid)
        if not target:
            raise HTTPException(404)
    return _render(request, "user_form.html", target_user=target, error=None)


@app.post("/users/{uid}/edit")
def user_update(
    request: Request, uid: int,
    role: str = Form(...),
    email: str = Form(""),
    is_active: str = Form("off"),
    new_password: str = Form(""),
):
    if not request.state.user or not request.state.user.is_admin():
        raise HTTPException(403)
    if role not in ("admin", "operator", "viewer"):
        raise HTTPException(400, "Неверная роль")
    with Session(engine) as s:
        target = s.get(User, uid)
        if not target:
            raise HTTPException(404)
        target.role = role
        target.email = email or None
        target.is_active = (is_active == "on")
        if new_password:
            if len(new_password) < 6:
                return _render(request, "user_form.html", target_user=target,
                               error="Пароль минимум 6 символов")
            target.password_hash = auth.hash_password(new_password)
        s.add(target)
        s.commit()
    return RedirectResponse("/users", status_code=303)


@app.post("/users/{uid}/delete")
def user_delete(request: Request, uid: int):
    me = request.state.user
    if not me or not me.is_admin():
        raise HTTPException(403)
    if me.id == uid:
        raise HTTPException(400, "Нельзя удалить себя")
    with Session(engine) as s:
        target = s.get(User, uid)
        if not target:
            raise HTTPException(404)
        s.delete(target)
        s.commit()
    return RedirectResponse("/users", status_code=303)


# ---------------------------------------------------------------- profile
@app.get("/profile", response_class=HTMLResponse)
def profile_page(request: Request):
    if not request.state.user:
        return RedirectResponse("/login", status_code=303)
    return _render(request, "profile.html", error=None, success=None)


@app.post("/profile/password")
def profile_change_password(
    request: Request,
    old_password: str = Form(...),
    new_password: str = Form(...),
):
    user = request.state.user
    if not user:
        return RedirectResponse("/login", status_code=303)
    if not auth.verify_password(old_password, user.password_hash):
        return _render(request, "profile.html", error="Старый пароль неверен", success=None)
    if len(new_password) < 6:
        return _render(request, "profile.html", error="Минимум 6 символов", success=None)
    with Session(engine) as s:
        db_user = s.get(User, user.id)
        db_user.password_hash = auth.hash_password(new_password)
        s.add(db_user)
        s.commit()
    return _render(request, "profile.html", error=None, success="Пароль обновлён")


# ---------------------------------------------------------------- sync helper
def _apply_services_sync() -> None:
    """Запускает add-service.sh, чтобы переприменить сервисы на Pi и внешнем сервере."""
    import subprocess
    script = config.PROJECT_ROOT / "scripts" / "add-service.sh"
    if not script.exists():
        return
    try:
        subprocess.run(
            ["bash", str(script)],
            check=True, timeout=180, capture_output=True,
            cwd=str(config.PROJECT_ROOT),
        )
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.decode(errors="replace") if e.stderr else str(e)
        raise RuntimeError(stderr)


# ---------------------------------------------------------------- healthcheck
@app.get("/healthz")
def healthz():
    return {"ok": True, "time": datetime.utcnow().isoformat()}
