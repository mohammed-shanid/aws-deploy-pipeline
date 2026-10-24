"""Configuration read from environment variables.

APP_ENV     deployment environment. Unset is treated as "prod" so a deploy that
            forgets to set it fails closed instead of silently running in dev mode.
DEMO_SECRET demo secret. Required unless APP_ENV=dev. Never logged or returned.
GIT_SHA     release identifier, set by the deploy. Defaults to "unknown".
"""

import os
from collections.abc import Mapping
from dataclasses import dataclass, field

DEV_ENV = "dev"


class ConfigError(Exception):
    """Raised when required configuration is missing or invalid."""


@dataclass(frozen=True)
class Settings:
    app_env: str
    git_sha: str
    # repr=False keeps the value out of reprs, tracebacks and log formatting.
    demo_secret: str | None = field(default=None, repr=False)


def load_settings(environ: Mapping[str, str] | None = None) -> Settings:
    env = os.environ if environ is None else environ

    app_env = env.get("APP_ENV", "").strip() or "prod"
    git_sha = env.get("GIT_SHA", "").strip() or "unknown"
    demo_secret = env.get("DEMO_SECRET") or None

    if demo_secret is None and app_env != DEV_ENV:
        raise ConfigError(
            f"DEMO_SECRET is not set and APP_ENV={app_env!r}. "
            f"It is required in every environment except {DEV_ENV!r}."
        )

    return Settings(app_env=app_env, git_sha=git_sha, demo_secret=demo_secret)
