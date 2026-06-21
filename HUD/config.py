"""Load HUD credentials and endpoints for the standalone training workspace."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from hud.settings import Settings, get_settings

HUD_ROOT = Path(__file__).resolve().parent
REPO_ROOT = HUD_ROOT.parent


def load_settings() -> Settings:
    """Prefer repo-root .env, then HUD/.env, then ~/.hud/.env (via hud settings)."""
    for env_file in (REPO_ROOT / ".env", HUD_ROOT / ".env"):
        if env_file.is_file():
            os.environ.setdefault("DOTENV_PATH", str(env_file))
            return Settings(_env_file=str(env_file))
    return get_settings()


@dataclass(frozen=True, slots=True)
class HUDConnection:
    api_key: str
    api_url: str
    gateway_url: str
    rl_url: str
    runtime_url: str
    telemetry_dir: Path | None

    @classmethod
    def from_settings(cls, settings: Settings | None = None) -> HUDConnection:
        s = settings or load_settings()
        if not s.api_key:
            raise ValueError(
                "HUD_API_KEY is not set. Add it to the repo root .env or run: hud login"
            )
        telemetry = os.environ.get("HUD_TELEMETRY_LOCAL_DIR")
        return cls(
            api_key=s.api_key,
            api_url=s.hud_api_url.rstrip("/"),
            gateway_url=s.hud_gateway_url.rstrip("/"),
            rl_url=s.hud_rl_url.rstrip("/"),
            runtime_url=s.hud_runtime_url.rstrip("/"),
            telemetry_dir=Path(telemetry).expanduser() if telemetry else None,
        )
