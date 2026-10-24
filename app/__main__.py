"""Entry point: `python -m app`.

HOST and PORT choose the bind address (defaults 127.0.0.1:8000). Uvicorn handles
SIGTERM/SIGINT: it stops accepting connections, lets in-flight requests finish
(up to SHUTDOWN_TIMEOUT_SECONDS), runs the lifespan shutdown, then re-raises
the signal, so the process exits 143 (128 + SIGTERM) as Docker/systemd expect.
Exits 2 if configuration is invalid.
"""

import logging
import os
import sys

import uvicorn

from app.config import ConfigError
from app.logging_setup import configure_logging
from app.main import create_app

SHUTDOWN_TIMEOUT_SECONDS = 10
EXIT_CONFIG_ERROR = 2


def main() -> None:
    configure_logging()
    try:
        app = create_app()
    except ConfigError as exc:
        logging.getLogger("app").error("configuration error: %s", exc)
        sys.exit(EXIT_CONFIG_ERROR)

    uvicorn.run(
        app,
        host=os.environ.get("HOST", "127.0.0.1"),
        port=int(os.environ.get("PORT", "8000")),
        log_config=None,
        access_log=False,
        timeout_graceful_shutdown=SHUTDOWN_TIMEOUT_SECONDS,
    )


if __name__ == "__main__":
    main()
