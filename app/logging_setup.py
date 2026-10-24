"""Structured JSON logging to stdout."""

import json
import logging
import sys
from datetime import UTC, datetime

# Extra fields copied from a LogRecord into the JSON line. Anything not listed
# here is dropped, so request headers or secrets cannot leak in via `extra=`.
_ALLOWED_EXTRAS = ("method", "path", "status", "duration_ms", "app_env", "git_sha")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for key in _ALLOWED_EXTRAS:
            if hasattr(record, key):
                entry[key] = getattr(record, key)
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry)


def configure_logging(level: int = logging.INFO) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
    # Uvicorn's loggers propagate to root; the access log is replaced by our
    # request middleware, which logs only method, path, status and latency.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        logging.getLogger(name).handlers.clear()
        logging.getLogger(name).propagate = True
