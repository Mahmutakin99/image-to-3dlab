import pytest
from maintenance_api import Maintenance, MaintenanceBusy


def test_busy_jobs_prevent_maintenance():
    gate = Maintenance()
    with pytest.raises(MaintenanceBusy):
        gate.begin(["skin"])
    assert not gate.active


def test_lease_requires_its_token_to_resume():
    gate = Maintenance()
    token = gate.begin([])
    assert gate.active
    with pytest.raises(PermissionError):
        gate.end("wrong")
    assert gate.active
    gate.end(token)
    assert not gate.active


def test_second_updater_cannot_take_over_lease():
    gate = Maintenance()
    token = gate.begin([])
    with pytest.raises(MaintenanceBusy):
        gate.begin([])
    gate.end(token)


def test_handler_blocks_mutations_during_maintenance(monkeypatch):
    import generate_api
    from io import BytesIO
    gate = Maintenance()
    token = gate.begin([])
    monkeypatch.setattr(generate_api, "MAINTENANCE", gate, raising=False)
    monkeypatch.setattr(generate_api.usage_api, "note_request", lambda *args: None)
    handler = object.__new__(generate_api.Handler)
    handler.path = "/api/chains"
    handler.headers = {}
    handler.rfile = BytesIO(b"{}")
    handler._allowed = lambda **kw: True
    handler._route_post = lambda: pytest.fail("A mutation reached the router during maintenance")
    responses = []
    handler._send_json = lambda status, body: responses.append((status, body))
    handler.do_POST()
    assert responses[0][0] == 503
    gate.end(token)


@pytest.mark.parametrize("busy", [False, True])
def test_handler_lease_checks_jobs_and_can_resume(monkeypatch, busy):
    import generate_api
    import json
    from io import BytesIO
    from types import SimpleNamespace
    gate = Maintenance()
    monkeypatch.setattr(generate_api, "MAINTENANCE", gate)
    monkeypatch.setattr(generate_api, "HEAVY_JOBS", {"skin": lambda: busy})
    monkeypatch.setattr(generate_api, "DOWNLOADS", {})
    handler = object.__new__(generate_api.Handler)
    handler.path = "/api/maintenance/begin"
    handler.headers = {"Content-Length": "2"}
    handler.rfile = BytesIO(b"{}")
    handler._chains = lambda: SimpleNamespace(running=lambda: None)
    responses = []
    handler._send_json = lambda status, body: responses.append((status, body))
    handler._maintenance_post()
    if busy:
        assert responses[0][0] == 409
        assert not gate.active
    else:
        assert responses[0][0] == 200
        body = json.dumps({"token": responses[0][1]["token"]}).encode()
        handler.path = "/api/maintenance/end"
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = BytesIO(body)
        handler._maintenance_post()
        assert responses[-1] == (200, {"active": False})
        assert not gate.active


@pytest.mark.parametrize("owner_ok,lease_ok,expected", [(True, True, 202), (False, True, 403), (True, False, 403)])
def test_shutdown_requires_app_ownership_and_maintenance_lease(monkeypatch, owner_ok, lease_ok, expected):
    import generate_api
    import json
    import threading
    from io import BytesIO
    from types import SimpleNamespace
    gate = Maintenance()
    token = gate.begin([])
    monkeypatch.setattr(generate_api, "MAINTENANCE", gate)
    monkeypatch.setenv("I3D_DESKTOP_OWNER", "test-owner")
    stopped = threading.Event()
    handler = object.__new__(generate_api.Handler)
    handler.server = SimpleNamespace(shutdown=stopped.set)
    handler.path = "/api/maintenance/shutdown"
    body = json.dumps({"token": token if lease_ok else "invalid"}).encode()
    handler.headers = {"Content-Length": str(len(body)), "X-AssetFurnace-Owner": "test-owner" if owner_ok else "other"}
    handler.rfile = BytesIO(body)
    responses = []
    handler._send_json = lambda status, result: responses.append((status, result))
    handler._maintenance_post()
    assert responses[0][0] == expected
    if expected == 202:
        assert stopped.wait(timeout=2)
    else:
        assert not stopped.is_set()


def test_runtime_identity_never_exposes_owner_secret():
    from maintenance_api import runtime_identity
    identity = runtime_identity({"I3D_DESKTOP_OWNER": "private", "I3D_DESKTOP_INSTANCE": "instance",
                                 "I3D_DESKTOP_COMMIT": "commit"})
    assert identity == {"schema_version": 1, "managed": True, "instance": "instance", "commit": "commit"}
    assert "private" not in str(identity)
    assert runtime_identity({})["managed"] is False
