"""Сессии и RBAC. Пароли — через bcrypt напрямую (без passlib)."""
from __future__ import annotations
from typing import Optional

import bcrypt
from fastapi import Request, HTTPException, status
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired
from sqlmodel import Session, select

from . import config
from .db import engine
from .models import User

_serializer = URLSafeTimedSerializer(config.WEB_SECRET, salt="morozovka-session")

COOKIE_NAME = "morozovka_session"


def hash_password(password: str) -> str:
    return bcrypt.hashpw(
        password.encode("utf-8"),
        bcrypt.gensalt(rounds=12),
    ).decode("utf-8")


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return bcrypt.checkpw(
            password.encode("utf-8"),
            password_hash.encode("utf-8"),
        )
    except (ValueError, TypeError):
        return False


def create_session_token(user_id: int) -> str:
    return _serializer.dumps({"uid": user_id})


def read_session_token(token: str) -> Optional[int]:
    try:
        data = _serializer.loads(token, max_age=config.WEB_SESSION_MAX_AGE)
        return int(data["uid"])
    except (BadSignature, SignatureExpired, KeyError, ValueError):
        return None


# ---------- User lookup ----------
def get_user_by_id(user_id: int) -> Optional[User]:
    with Session(engine) as s:
        return s.get(User, user_id)


def get_user_by_username(username: str) -> Optional[User]:
    with Session(engine) as s:
        return s.exec(select(User).where(User.username == username)).first()


# ---------- FastAPI dependencies ----------
def current_user(request: Request) -> Optional[User]:
    if hasattr(request.state, "user"):
        return request.state.user
    return None


def require_user(request: Request) -> User:
    user = current_user(request)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_303_SEE_OTHER,
            headers={"Location": "/login"},
        )
    return user


def require_admin(request: Request) -> User:
    user = require_user(request)
    if not user.is_admin():
        raise HTTPException(status_code=403, detail="Требуются права администратора")
    return user
