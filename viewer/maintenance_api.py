"""Serialize updater leases with incoming mutations; no jobs are cancelled."""
from __future__ import annotations

import secrets
import threading


class MaintenanceBusy(RuntimeError):
    pass


class Maintenance:
    def __init__(self):
        self.lock = threading.RLock()
        self._token: str | None = None

    @property
    def active(self) -> bool:
        with self.lock:
            return self._token is not None

    def begin(self, busy: list[str]) -> str:
        with self.lock:
            if self.active or busy:
                raise MaintenanceBusy("Maintenance unavailable: " + ", ".join(busy or ["another updater"]))
            self._token = secrets.token_urlsafe(32)
            return self._token

    def authorizes(self, token: str) -> bool:
        with self.lock:
            return self._token is not None and secrets.compare_digest(self._token, token)

    def end(self, token: str) -> None:
        with self.lock:
            if self._token is None or not secrets.compare_digest(self._token, token):
                raise PermissionError("Invalid maintenance token")
            self._token = None


def runtime_identity(env: dict[str, str]) -> dict:
    """Public instance identity; the native application's owner credential stays private."""
    return {"schema_version": 1,
            "managed": bool(env.get("I3D_DESKTOP_OWNER") and env.get("I3D_DESKTOP_INSTANCE")),
            "instance": env.get("I3D_DESKTOP_INSTANCE"),
            "commit": env.get("I3D_DESKTOP_COMMIT")}
