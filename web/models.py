"""Модели данных."""
from __future__ import annotations
from datetime import datetime
from typing import Optional
from sqlmodel import SQLModel, Field


class User(SQLModel, table=True):
    __tablename__ = "users"

    id: Optional[int] = Field(default=None, primary_key=True)
    username: str = Field(unique=True, index=True, max_length=64)
    password_hash: str
    role: str = Field(default="viewer", max_length=16)  # admin | operator | viewer
    email: Optional[str] = Field(default=None, max_length=255)
    is_active: bool = Field(default=True)
    created_at: datetime = Field(default_factory=datetime.utcnow)

    def is_admin(self) -> bool:
        return self.role == "admin"

    def can_edit(self, service: "Service") -> bool:
        if self.role == "admin":
            return True
        if self.role == "operator":
            return service.owner_id == self.id
        return False


class Service(SQLModel, table=True):
    __tablename__ = "services"

    id: Optional[int] = Field(default=None, primary_key=True)
    name: str = Field(unique=True, index=True, max_length=64)
    domain: str = Field(default="_", max_length=253)
    internal_ip: str = Field(max_length=45)
    internal_port: int
    vpn_port: int
    type: str = Field(default="http", max_length=8)  # http | tcp
    external_port: int
    description: Optional[str] = Field(default=None, max_length=512)
    owner_id: Optional[int] = Field(default=None, foreign_key="users.id")
    enabled: bool = Field(default=True)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)

    @property
    def url_hint(self) -> str:
        scheme = "http"
        if self.type == "http":
            return f"{scheme}://{self.domain if self.domain != '_' else '<сервер>'}:{self.external_port}"
        return f"{self.type}://<сервер>:{self.external_port}"


class TestRun(SQLModel, table=True):
    __tablename__ = "test_runs"

    id: Optional[int] = Field(default=None, primary_key=True)
    service_id: int = Field(foreign_key="services.id", index=True)
    started_at: datetime = Field(default_factory=datetime.utcnow)
    finished_at: Optional[datetime] = None
    overall: str = Field(default="running", max_length=8)  # ok | warn | fail | running
    steps_json: str = Field(default="[]")
    triggered_by: Optional[int] = Field(default=None, foreign_key="users.id")
