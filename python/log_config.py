"""Shared file logging — mirrors to ~/yc/logs/ for agent debugging."""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from pathlib import Path

APP_LOG_DIR = Path.home() / "Library/Application Support/OpenHive/logs"
DEV_LOG_DIR = Path.home() / "yc/logs"


def _ensure_dirs() -> None:
    APP_LOG_DIR.mkdir(parents=True, exist_ok=True)
    DEV_LOG_DIR.mkdir(parents=True, exist_ok=True)


class JsonLineFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": time.time(),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info and record.exc_info[1]:
            payload["error"] = str(record.exc_info[1])
        extra = getattr(record, "extra_data", None)
        if extra:
            payload["data"] = extra
        return json.dumps(payload, default=str)


def _mirror_handler() -> logging.Handler:
    path = DEV_LOG_DIR / "engine.log"
    handler = logging.FileHandler(path, encoding="utf-8")
    handler.setFormatter(JsonLineFormatter())
    return handler


def _app_handler() -> logging.Handler:
    path = APP_LOG_DIR / "engine.log"
    handler = logging.FileHandler(path, encoding="utf-8")
    handler.setFormatter(JsonLineFormatter())
    return handler


def setup_logging(name: str = "openhive") -> logging.Logger:
    _ensure_dirs()
    logger = logging.getLogger(name)
    if logger.handlers:
        return logger
    logger.setLevel(logging.DEBUG)
    logger.addHandler(_app_handler())
    logger.addHandler(_mirror_handler())
    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.INFO)
    console.setFormatter(logging.Formatter("%(levelname)s:%(name)s:%(message)s"))
    logger.addHandler(console)
    return logger


def log_event(logger: logging.Logger, msg: str, **data) -> None:
    record = logger.makeRecord(
        logger.name, logging.INFO, "", 0, msg, (), None
    )
    record.extra_data = data  # type: ignore[attr-defined]
    logger.handle(record)
