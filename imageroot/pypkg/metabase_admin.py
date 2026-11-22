# SPDX-License-Identifier: GPL-3.0-or-later
"""Optional first administrator of Metabase.

Metabase has no environment variable for its first administrator: the first
person who opens the site walks through the setup wizard, which calls
POST /api/setup with a one-time token that GET /api/session/properties
publishes until the first account exists (metabase/src/metabase/setup.clj and
api/setup.clj). MB_ADMIN_EMAIL is only the contact address shown to users.

When the NS8 administrator gives an email and a password, the module calls that
same endpoint once, as soon as Metabase answers, so nobody else can claim the
instance. It never touches an instance that already has an account (upgrade
from 1.0.0, or a wizard finished in the browser).

The password is write-only: kept in state/admin.env (mode 0600) only until it
is used, sent in the request body (never in argv) and then deleted. It is not
part of the backup and never returned by get-configuration.
"""
import json
import os
import re
import time
import urllib.error
import urllib.request
from pathlib import Path

PATH_NAME = "admin.env"
MIN_LENGTH = 12
EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s]+")


class AdminError(ValueError):
    def __init__(self, field, key):
        super().__init__(key)
        self.field = field
        self.key = key


class SetupRefused(RuntimeError):
    """Metabase answered but rejected the account: retrying the same data is pointless."""


def path():
    return Path(os.environ.get("AGENT_STATE_DIR", ".")) / PATH_NAME


def read():
    values = {}
    try:
        for line in path().read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep:
                values[key] = value
    except FileNotFoundError:
        pass
    return values


def pending():
    """True while an administrator waits for Metabase to be ready."""
    values = read()
    return bool(values.get("ADMIN_EMAIL") and values.get("ADMIN_PASSWORD"))


def email():
    return read().get("ADMIN_EMAIL", "")


def base_url():
    return f"http://127.0.0.1:{os.environ['TCP_PORT']}"


def probe():
    """Public properties of the running Metabase, or None when it does not answer."""
    try:
        with urllib.request.urlopen(base_url() + "/api/session/properties", timeout=3) as response:
            value = json.load(response)
        return value if isinstance(value, dict) and "has-user-setup" in value else None
    except Exception:
        return None


def setup_complete():
    """True/False from the running Metabase, None when it cannot be asked."""
    properties = probe()
    return None if properties is None else bool(properties["has-user-setup"])


def validate(request):
    """Return (email, password) to store, or None when the request has no administrator.

    Raise AdminError with the i18n key of the problem. Never echo the password.
    """
    new_email = (request.get("admin_email") or "").strip()
    new_password = request.get("admin_password") or ""
    if not new_password and not new_email:
        return None
    address = (new_email or email()).lower()
    if not EMAIL.fullmatch(address) or len(address) > 254:
        raise AdminError("admin_email", "admin_email_invalid")
    if not new_password:
        raise AdminError("admin_password", "admin_password_required")
    if len(new_password) < MIN_LENGTH or len(new_password.encode()) > 72:
        raise AdminError("admin_password", "admin_password_length")
    if any(ord(c) < 32 or ord(c) == 127 for c in new_password):
        raise AdminError("admin_password", "admin_password_invalid")
    if setup_complete():
        raise AdminError("admin_email", "admin_already_created")
    return address, new_password


def store(values):
    address, password = values
    target = path()
    tmp = target.with_name(target.name + f".{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(f"ADMIN_EMAIL={address}\nADMIN_PASSWORD={password}\n")
        os.replace(tmp, target)
    finally:
        tmp.unlink(missing_ok=True)


def discard():
    path().unlink(missing_ok=True)


def wait_ready(timeout):
    """Wait until Metabase answers its public properties. Returns them, or None on timeout."""
    deadline = time.monotonic() + timeout
    while True:
        properties = probe()
        if properties is not None:
            return properties
        if time.monotonic() >= deadline:
            return None
        time.sleep(5)


def create(address, password, properties):
    """Call POST /api/setup once. Returns "created" or "exists"."""
    if properties.get("has-user-setup"):
        return "exists"
    token = properties.get("setup-token")
    if not token:
        raise RuntimeError("Metabase offers no setup token yet")
    body = json.dumps({
        "token": token,
        "user": {"email": address, "password": password,
                 "first_name": "Metabase", "last_name": "Administrator"},
        "prefs": {"site_name": "Metabase", "site_locale": "en"},
    }).encode()
    request = urllib.request.Request(base_url() + "/api/setup", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            response.read()
    except urllib.error.HTTPError as error:
        # Metabase names the rejected fields: report those, never the body
        try:
            fields = ", ".join(sorted((json.load(error).get("errors") or {}).keys()))
        except Exception:
            fields = ""
        raise SetupRefused(f"Metabase refused the administrator account (HTTP {error.code}"
                           + (f", field: {fields}" if fields else "") + ")") from None
    except Exception as error:
        raise RuntimeError(f"Metabase setup request failed ({type(error).__name__})") from None
    return "created"


def apply(timeout=480):
    """Create the pending administrator once Metabase is up. Returns "none", "created" or "exists"."""
    if not pending():
        return "none"
    values = read()
    properties = wait_ready(timeout)
    if properties is None:
        raise RuntimeError("Metabase did not become ready in time: save the settings again to retry")
    try:
        outcome = create(values["ADMIN_EMAIL"], values["ADMIN_PASSWORD"], properties)
    except SetupRefused:
        discard()  # a refused password must not stay on disk
        raise
    discard()
    return outcome
