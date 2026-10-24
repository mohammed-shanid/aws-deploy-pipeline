import json
import logging
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from app import __main__ as entrypoint
from app.config import ConfigError, Settings, load_settings
from app.logging_setup import JsonFormatter
from app.main import create_app

SECRET = "s3cr3t-value-for-tests"


def make_settings(**overrides: str) -> Settings:
    values = {"app_env": "test", "git_sha": "abc123", "demo_secret": SECRET}
    values.update(overrides)
    return Settings(**values)


# /health


def test_health_ok_once_started() -> None:
    with TestClient(create_app(make_settings())) as client:
        response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_health_unavailable_before_startup() -> None:
    # Without the context manager the lifespan startup never runs.
    client = TestClient(create_app(make_settings()))
    response = client.get("/health")
    assert response.status_code == 503
    assert response.json() == {"status": "unavailable"}


# /version


def test_version_reports_git_sha_and_start_time() -> None:
    sha = "0123456789abcdef0123456789abcdef01234567"
    with TestClient(create_app(make_settings(git_sha=sha))) as client:
        body = client.get("/version").json()
    assert body["git_sha"] == sha
    assert datetime.fromisoformat(body["started_at"]).tzinfo is not None
    assert set(body) == {"git_sha", "started_at"}


def test_version_git_sha_read_from_env() -> None:
    settings = load_settings({"APP_ENV": "dev", "GIT_SHA": "deadbeef"})
    assert settings.git_sha == "deadbeef"
    assert load_settings({"APP_ENV": "dev"}).git_sha == "unknown"


# index


def test_index_page() -> None:
    with TestClient(create_app(make_settings())) as client:
        response = client.get("/")
    assert response.status_code == 200
    assert "aws-deploy-pipeline demo" in response.text


# missing secret


@pytest.mark.parametrize(
    "environ",
    [
        {"APP_ENV": "prod"},
        {"APP_ENV": "staging", "DEMO_SECRET": ""},
        {},  # unset APP_ENV is treated as prod
    ],
)
def test_missing_secret_fails_outside_dev(environ: dict[str, str]) -> None:
    with pytest.raises(ConfigError, match="DEMO_SECRET is not set"):
        load_settings(environ)


def test_missing_secret_allowed_in_dev() -> None:
    settings = load_settings({"APP_ENV": "dev"})
    assert settings.app_env == "dev"
    assert settings.demo_secret is None


def test_secret_read_from_env() -> None:
    assert load_settings({"APP_ENV": "prod", "DEMO_SECRET": SECRET}).demo_secret == SECRET


def test_create_app_fails_fast_without_secret(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.delenv("DEMO_SECRET", raising=False)
    with pytest.raises(ConfigError):
        create_app()


def test_entrypoint_exits_with_clear_error(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.delenv("DEMO_SECRET", raising=False)
    # main() reconfigures the root logger; restore it after the test.
    root = logging.getLogger()
    monkeypatch.setattr(root, "handlers", [])
    monkeypatch.setattr(root, "level", root.level)
    with pytest.raises(SystemExit) as exc_info:
        entrypoint.main()
    assert exc_info.value.code == entrypoint.EXIT_CONFIG_ERROR
    line = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert line["level"] == "error"
    assert "DEMO_SECRET is not set" in line["msg"]


# logging


def test_request_log_is_json_without_headers_or_secret(
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.INFO)
    with TestClient(create_app(make_settings())) as client:
        client.get("/version?token=xyz", headers={"Authorization": "Bearer hunter2"})

    request_records = [r for r in caplog.records if r.getMessage() == "request"]
    assert len(request_records) == 1
    line = json.loads(JsonFormatter().format(request_records[0]))
    assert line["path"] == "/version"
    assert line["status"] == 200
    assert isinstance(line["duration_ms"], float)

    # Only the server side's own logs; the test client logs the full URL itself.
    server_records = [r for r in caplog.records if r.name.split(".")[0] in ("app", "uvicorn")]
    all_output = "\n".join(JsonFormatter().format(r) for r in server_records)
    for leaked in (SECRET, "hunter2", "Authorization", "token=xyz"):
        assert leaked not in all_output


def test_secret_not_in_settings_repr() -> None:
    assert SECRET not in repr(make_settings())
