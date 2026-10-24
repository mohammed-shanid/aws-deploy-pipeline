"""HTTP application: /health, /version and a tiny index page."""

import logging
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from datetime import UTC, datetime

from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse

from app.config import Settings, load_settings

logger = logging.getLogger("app")

INDEX_HTML = """<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>aws-deploy-pipeline demo</title></head>
<body>
<h1>aws-deploy-pipeline demo</h1>
<p>A minimal FastAPI app used as the deployment target for a small AWS pipeline:
Terraform, Ansible, Docker, GitHub Actions and CloudWatch.</p>
<p>See <a href="/health">/health</a> and <a href="/version">/version</a>.</p>
</body>
</html>
"""


def create_app(settings: Settings | None = None) -> FastAPI:
    # Load (and validate) config before anything else so a missing secret
    # stops startup instead of surfacing later at request time.
    settings = settings if settings is not None else load_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.started_at = datetime.now(UTC).isoformat(timespec="seconds")
        app.state.ready = True
        logger.info(
            "startup complete", extra={"app_env": settings.app_env, "git_sha": settings.git_sha}
        )
        yield
        app.state.ready = False
        logger.info("shutdown complete")

    app = FastAPI(
        title="aws-deploy-pipeline demo",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.settings = settings
    app.state.ready = False
    app.state.started_at = None

    @app.middleware("http")
    async def log_requests(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        start = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        finally:
            # Path only: no query string, headers or body.
            logger.info(
                "request",
                extra={
                    "method": request.method,
                    "path": request.url.path,
                    "status": status,
                    "duration_ms": round((time.perf_counter() - start) * 1000, 2),
                },
            )

    @app.get("/health")
    async def health(request: Request) -> JSONResponse:
        if not request.app.state.ready:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        return JSONResponse({"status": "ok"})

    @app.get("/version")
    async def version(request: Request) -> dict[str, str | None]:
        return {
            "git_sha": request.app.state.settings.git_sha,
            "started_at": request.app.state.started_at,
        }

    @app.get("/", response_class=HTMLResponse)
    async def index() -> str:
        return INDEX_HTML

    return app
