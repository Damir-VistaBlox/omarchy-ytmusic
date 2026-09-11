"""Where the plugin keeps its YouTube Music session, and how it gets one.

The session lives outside the plugin repository in ``~/.config/omarchy-ytmusic``
(0700), overridable with ``YTM_CONFIG_DIR``:

- ``browser.json`` (0600): ytmusicapi browser-auth headers
- ``cookies.txt``  (0600): the same session for yt-dlp/mpv (Netscape format)
- ``account.json`` (0600): display name/handle/photo only, no secrets; the
  shell reads this one to know whether you are signed in

Default sign-in imports the session cookies straight from a Chromium profile.
Pasting request headers is the fallback; it goes through the clipboard, whose
history Omarchy stores in plain text.
"""

import json
import os
import shutil
import tempfile
import time
from pathlib import Path

import ytm_normalize as norm

CHROMIUM_PROFILES = (
    Path.home() / ".config/chromium/Default",
)
SESSION_FILES = ("browser.json", "cookies.txt", "account.json")
REQUIRED_COOKIE = "__Secure-3PAPISID"


class AuthError(Exception):
    pass


def config_dir():
    return Path(os.environ.get("YTM_CONFIG_DIR") or Path.home() / ".config/omarchy-ytmusic")


def browser_path():
    return config_dir() / "browser.json"


def cookies_path():
    return config_dir() / "cookies.txt"


def account_path():
    return config_dir() / "account.json"


def ensure_config_dir():
    path = config_dir()
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def write_private(path, text):
    previous = os.umask(0o077)
    try:
        tmp = Path(f"{path}.tmp")
        tmp.write_text(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        os.umask(previous)


def _ytmusic_class():
    from ytmusicapi import YTMusic

    return YTMusic


def load_client(factory=None):
    """Return ``(client, state)`` with state ``"ok"``, ``"none"`` or ``"invalid"``."""
    make = factory or _ytmusic_class()
    path = browser_path()
    if not path.exists():
        return make(), "none"
    try:
        client = make(str(path))
    except Exception as exc:  # noqa: BLE001 - any failure means the file is unusable
        norm.log(f"saved session is unusable ({type(exc).__name__}); continuing signed out")
        return make(), "invalid"
    remember_visitor_id(path, client)
    return client, "ok"


def remember_visitor_id(path, client):
    """Save the visitor id ytmusicapi fetched into browser.json.

    Without one in the headers, ytmusicapi fetches it over the network on every
    start (~0.8 s), which would delay the worker's first answer.
    """
    try:
        visitor_id = (getattr(client, "headers", None) or {}).get("X-Goog-Visitor-Id")
        saved = json.loads(Path(path).read_text())
    except (OSError, ValueError, AttributeError):
        return
    if not visitor_id or any(key.lower() == "x-goog-visitor-id" for key in saved):
        return
    saved["x-goog-visitor-id"] = visitor_id
    write_private(Path(path), json.dumps(saved, indent=4, sort_keys=True) + "\n")


def whoami():
    try:
        return json.loads(account_path().read_text())
    except (OSError, ValueError):
        return None


def logout():
    removed = []
    for name in SESSION_FILES:
        path = config_dir() / name
        if path.exists():
            path.unlink()
            removed.append(name)
    return removed


# ---- cookie formats -------------------------------------------------------


def cookie_record(domain, name, value, path="/", secure=True, expires=0):
    return {"domain": domain, "path": path or "/", "secure": bool(secure),
            "expires": int(expires or 0), "name": name, "value": value or ""}


def cookies_txt(cookies):
    """Netscape cookie file, as read by yt-dlp's ``--cookies``."""
    lines = ["# Netscape HTTP Cookie File"]
    for c in cookies:
        lines.append("\t".join([
            c["domain"],
            "TRUE" if c["domain"].startswith(".") else "FALSE",
            c["path"],
            "TRUE" if c["secure"] else "FALSE",
            str(c["expires"]),
            c["name"],
            c["value"],
        ]))
    return "\n".join(lines) + "\n"


def cookies_from_header(header):
    """Records for ``.youtube.com`` from a ``name=value; name=value`` header."""
    out = []
    for part in (header or "").split(";"):
        name, sep, value = part.strip().partition("=")
        if sep and name:
            out.append(cookie_record(".youtube.com", name, value))
    return out


def headers_raw(cookie_header, authuser=0):
    """Request headers in the form ``ytmusicapi.setup(headers_raw=...)`` expects.

    The SAPISIDHASH value is a placeholder: ytmusicapi only uses it to detect
    browser auth and recomputes the real one for every request.
    """
    return "\n".join([
        "accept: */*",
        "authorization: SAPISIDHASH 0_placeholder",
        "content-type: application/json",
        f"cookie: {cookie_header}",
        f"x-goog-authuser: {authuser}",
        "x-origin: https://music.youtube.com",
    ])


def _setup_browser_json(path, raw):
    import ytmusicapi

    previous = os.umask(0o077)
    try:
        ytmusicapi.setup(filepath=str(path), headers_raw=raw)
    finally:
        os.umask(previous)
    os.chmod(path, 0o600)


# ---- sign-in ----------------------------------------------------------------


def commit_session(write_browser, cookies, method, factory=None):
    """Write and verify a new session in a private temp dir, then swap it in.

    A session that fails verification never replaces the one already saved.
    ``cookies`` may be ``None`` to derive cookies.txt from browser.json.
    """
    directory = ensure_config_dir()
    staging = Path(tempfile.mkdtemp(prefix=".new-", dir=directory))
    try:
        write_browser(staging / "browser.json")
        if cookies is None:
            header = json.loads((staging / "browser.json").read_text()).get("cookie", "")
            cookies = cookies_from_header(header)
        write_private(staging / "cookies.txt", cookies_txt(cookies))
        make = factory or _ytmusic_class()
        try:
            client = make(str(staging / "browser.json"))
            info = client.get_account_info()
        except Exception as exc:  # noqa: BLE001
            raise AuthError(f"YouTube Music did not accept this session ({type(exc).__name__}: {exc})") from exc
        remember_visitor_id(staging / "browser.json", client)
        account = norm.account(info)
        account.update({"method": method, "createdAt": int(time.time())})
        write_private(staging / "account.json", json.dumps(account, indent=2) + "\n")
        for name in SESSION_FILES:
            os.chmod(staging / name, 0o600)
            os.replace(staging / name, directory / name)
        return account
    finally:
        shutil.rmtree(staging, ignore_errors=True)


class _QuietLogger:
    def debug(self, message, **kwargs):
        pass

    def info(self, message, **kwargs):
        pass

    def warning(self, message, **kwargs):
        norm.log(f"yt-dlp: {message}")

    def error(self, message, **kwargs):
        norm.log(f"yt-dlp: {message}")


def find_profile(browser, profile=None):
    if profile:
        return str(Path(profile).expanduser())
    if browser == "chromium":
        for candidate in CHROMIUM_PROFILES:
            if (candidate / "Cookies").exists() or (candidate / "Network" / "Cookies").exists():
                return str(candidate)
    return None


def import_from_browser(browser="chromium", profile=None, authuser=0, keyring="GNOMEKEYRING",
                        factory=None, extractor=None):
    """Sign in with the YouTube cookies of a local browser profile."""
    profile = find_profile(browser, profile)
    if browser == "chromium" and not profile:
        raise AuthError("no Chromium profile found; pass --from-browser chromium:/path/to/profile")
    if extractor is None:
        from yt_dlp.cookies import extract_cookies_from_browser as extractor
    jar = extractor(browser, profile=profile, logger=_QuietLogger(), keyring=keyring)
    youtube = [c for c in jar if c.domain.endswith("youtube.com")]
    if REQUIRED_COOKIE not in {c.name for c in youtube}:
        raise AuthError("that profile is not signed in to YouTube (open music.youtube.com there and sign in)")
    header = "; ".join(f"{c.name}={c.value}" for c in youtube
                       if c.domain in (".youtube.com", "youtube.com", "music.youtube.com"))
    file_cookies = [cookie_record(c.domain, c.name, c.value, c.path, c.secure, c.expires)
                    for c in jar if c.domain.endswith(("youtube.com", "google.com"))]
    raw = headers_raw(header, authuser)
    return commit_session(lambda path: _setup_browser_json(path, raw), file_cookies,
                          f"browser:{browser}", factory)


def import_from_headers(raw, factory=None):
    """Sign in with pasted request headers of a music.youtube.com /browse call."""
    if "cookie" not in (raw or "").lower():
        raise AuthError("those headers contain no cookie; copy the request headers of a /browse request")
    return commit_session(lambda path: _setup_browser_json(path, raw), None, "headers", factory)
