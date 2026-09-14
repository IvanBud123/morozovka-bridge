#!/usr/bin/env python3
"""CLI: init-db, create-admin, import, set-password, list-users."""
from __future__ import annotations
import argparse
import getpass
import sys
from sqlmodel import Session, select

from .db import engine, init_db
from .models import User, Service
from .auth import hash_password
from . import config_manager


def cmd_init_db(_args):
    init_db()
    print("[+] БД инициализирована")


def cmd_import(_args):
    n = config_manager.import_from_config_env()
    print(f"[+] Импортировано сервисов: {n}")


def cmd_create_admin(args):
    init_db()
    with Session(engine) as s:
        existing = s.exec(select(User).where(User.username == args.username)).first()
        if existing:
            print(f"[!] Пользователь {args.username} уже существует")
            sys.exit(1)
        password = args.password or getpass.getpass("Пароль: ")
        if not password or len(password) < 6:
            print("[x] Пароль слишком короткий (минимум 6 символов)")
            sys.exit(1)
        user = User(
            username=args.username,
            password_hash=hash_password(password),
            role="admin",
            email=args.email,
        )
        s.add(user)
        s.commit()
        print(f"[+] Админ {args.username} создан")


def cmd_set_password(args):
    with Session(engine) as s:
        user = s.exec(select(User).where(User.username == args.username)).first()
        if not user:
            print(f"[x] Пользователь {args.username} не найден")
            sys.exit(1)
        password = args.password or getpass.getpass("Новый пароль: ")
        user.password_hash = hash_password(password)
        s.add(user)
        s.commit()
        print(f"[+] Пароль для {args.username} обновлён")


def cmd_list_users(_args):
    with Session(engine) as s:
        users = s.exec(select(User)).all()
        print(f"{'ID':<4} {'Логин':<20} {'Роль':<10} {'Активен':<8} Email")
        for u in users:
            print(f"{u.id:<4} {u.username:<20} {u.role:<10} {str(u.is_active):<8} {u.email or ''}")


def cmd_list_services(_args):
    with Session(engine) as s:
        services = s.exec(select(Service)).all()
        print(f"{'ID':<4} {'Имя':<20} {'Внутр.':<22} {'Внешний':<10} {'Тип':<6} Владелец")
        for svc in services:
            internal = f"{svc.internal_ip}:{svc.internal_port}"
            print(f"{svc.id:<4} {svc.name:<20} {internal:<22} {svc.external_port:<10} {svc.type:<6} {svc.owner_id}")


def main():
    parser = argparse.ArgumentParser(prog="manage.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("init-db", help="Создать таблицы в БД")
    p.set_defaults(func=cmd_init_db)

    p = sub.add_parser("import", help="Импортировать SERVICES из config.env в БД")
    p.set_defaults(func=cmd_import)

    p = sub.add_parser("create-admin", help="Создать администратора")
    p.add_argument("username")
    p.add_argument("--password", default=None, help="Пароль (иначе спросит интерактивно)")
    p.add_argument("--email", default=None)
    p.set_defaults(func=cmd_create_admin)

    p = sub.add_parser("set-password", help="Сменить пароль пользователя")
    p.add_argument("username")
    p.add_argument("--password", default=None)
    p.set_defaults(func=cmd_set_password)

    p = sub.add_parser("list-users", help="Список пользователей")
    p.set_defaults(func=cmd_list_users)

    p = sub.add_parser("list-services", help="Список сервисов")
    p.set_defaults(func=cmd_list_services)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
