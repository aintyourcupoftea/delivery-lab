import os
import time

import pytest
from fastapi.testclient import TestClient

import app as app_module


@pytest.fixture()
def client():
    with TestClient(app_module.app) as c:
        yield c


def test_index_reports_version(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "test-1")
    body = client.get("/").json()
    assert body["service"] == "delivery-lab"
    assert body["version"] == "test-1"


def test_liveness_has_no_dependencies(client, monkeypatch):
    """Liveness must stay 200 even when the app refuses traffic.

    This is the Q2 invariant: a dependency outage must never make the kubelet
    restart the process.
    """
    monkeypatch.setenv("READY", "false")
    assert client.get("/health/live").status_code == 200


def test_readiness_fails_closed_when_not_ready(client, monkeypatch):
    monkeypatch.setenv("READY", "false")
    r = client.get("/health/ready")
    assert r.status_code == 503
    assert r.json()["ready"] is False


def test_readiness_ok_by_default(client, monkeypatch):
    monkeypatch.delenv("READY", raising=False)
    assert client.get("/health/ready").status_code == 200


def test_work_respects_delay(client, monkeypatch):
    monkeypatch.setenv("WORK_DELAY", "0.3")
    start = time.monotonic()
    assert client.get("/work").json() == {"ok": True}
    assert time.monotonic() - start >= 0.3


def test_sigterm_starts_a_drain_instead_of_closing_the_socket():
    """The zero-downtime invariant, asserted end to end.

    On SIGTERM the process must: return 503 from readiness, keep returning 200
    from liveness, keep serving real traffic for the drain window, and only
    then exit. If this regresses, rollouts start dropping connections.
    """
    import signal
    import subprocess
    import sys
    import urllib.error
    import urllib.request

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = dict(os.environ, PORT="8091", DRAIN_SECONDS="3", GRACEFUL_TIMEOUT="5")
    proc = subprocess.Popen([sys.executable, "app.py"], cwd=root, env=env)

    def code(path):
        try:
            return urllib.request.urlopen(f"http://127.0.0.1:8091{path}", timeout=3).status
        except urllib.error.HTTPError as exc:
            return exc.code

    try:
        for _ in range(40):  # wait for bind
            try:
                if code("/health/ready") == 200:
                    break
            except OSError:
                time.sleep(0.25)
        else:
            pytest.fail("server never became ready")

        started = time.monotonic()
        proc.send_signal(signal.SIGTERM)
        time.sleep(0.5)

        assert code("/health/ready") == 503, "readiness must fail during drain"
        assert code("/health/live") == 200, "liveness must stay up during drain"
        assert code("/") == 200, "must keep serving traffic during drain"

        proc.wait(timeout=20)
        assert time.monotonic() - started >= 2.5, "exited before draining"
    finally:
        if proc.poll() is None:
            proc.kill()


def test_no_secrets_in_environment_defaults():
    """Guard against someone hardcoding a credential into the app."""
    src = open(os.path.join(os.path.dirname(__file__), "..", "app.py")).read()
    for needle in ("password", "secret", "token", "api_key", "apikey"):
        assert needle not in src.lower(), f"possible hardcoded credential: {needle}"
