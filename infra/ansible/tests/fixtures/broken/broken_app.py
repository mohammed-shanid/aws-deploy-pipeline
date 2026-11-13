"""A deliberately broken release, used only by deploy_rollback_inner.sh.

BROKEN_MODE=health500  listen like the app, but /health returns 500
                       (the Phase 8 gate: "a health endpoint returning 500")
BROKEN_MODE=crash      exit 3 at startup, before listening
/version still answers in health500 mode, so a test that only checked /version
would wrongly accept this release; the deploy must gate on /health.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

EXIT_CRASH = 3


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        if self.path == "/version":
            status, body = 200, {"git_sha": os.environ.get("GIT_SHA", "unknown")}
        elif self.path == "/health":
            status, body = 500, {"status": "broken on purpose"}
        else:
            status, body = 404, {}
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    mode = os.environ.get("BROKEN_MODE", "health500")
    if mode == "crash":
        print("broken release: crashing on start", file=sys.stderr)
        sys.exit(EXIT_CRASH)
    port = int(os.environ.get("PORT", "8000"))
    HTTPServer((os.environ.get("HOST", "0.0.0.0"), port), Handler).serve_forever()  # noqa: S104


if __name__ == "__main__":
    main()
