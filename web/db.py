"""Подключение к БД и инициализация."""
from __future__ import annotations
from sqlmodel import SQLModel, Session, create_engine

from . import config
# ВАЖНО: импорт models нужен, чтобы SQLModel.metadata знал о таблицах
# до вызова create_all(). Не удалять, даже если IDE подсвечивает "unused".
from . import models  # noqa: F401

engine = create_engine(
    f"sqlite:///{config.WEB_DB_PATH}",
    echo=False,
    connect_args={"check_same_thread": False},
)


def init_db() -> None:
    SQLModel.metadata.create_all(engine)


def get_session():
    with Session(engine) as session:
        yield session
