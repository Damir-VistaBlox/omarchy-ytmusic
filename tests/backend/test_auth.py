import json
import stat
from types import SimpleNamespace

import pytest

import ytm_auth as auth


def mode(path):
    return stat.S_IMODE(path.stat().st_mode)


class FakeClient:
    accept = True

    def __init__(self, path=None):
        self.path = path

    def get_account_info(self):
        if not self.accept:
            raise RuntimeError("HTTP 401")
        return {"accountName": "Test User", "channelHandle": "@test", "accountPhotoUrl": "https://x/p.jpg"}


class RejectingClient(FakeClient):
    accept = False


class VisitorClient(FakeClient):
    headers = {"X-Goog-Visitor-Id": "VISITOR"}


def fake_setup(monkeypatch):
    def setup(path, raw):
        cookie = next(line.split(":", 1)[1].strip() for line in raw.splitlines() if line.lower().startswith("cookie:"))
        path.write_text(json.dumps({"cookie": cookie, "x-goog-authuser": "0"}))

    monkeypatch.setattr(auth, "_setup_browser_json", setup)


def test_cookies_txt_is_netscape_format():
    text = auth.cookies_txt([
        auth.cookie_record(".youtube.com", "A", "1", expires=1900000000),
        auth.cookie_record("music.youtube.com", "B", "2", secure=False),
    ])
    lines = text.splitlines()
    assert lines[0] == "# Netscape HTTP Cookie File"
    assert lines[1].split("\t") == [".youtube.com", "TRUE", "/", "TRUE", "1900000000", "A", "1"]
    assert lines[2].split("\t") == ["music.youtube.com", "FALSE", "/", "FALSE", "0", "B", "2"]


def test_cookies_from_header_and_headers_raw():
    records = auth.cookies_from_header("SID=abc; __Secure-3PAPISID=def; broken; X=")
    assert [(r["name"], r["value"]) for r in records] == [("SID", "abc"), ("__Secure-3PAPISID", "def"), ("X", "")]
    raw = auth.headers_raw("SID=abc", authuser=1)
    assert "cookie: SID=abc" in raw and "x-goog-authuser: 1" in raw and "SAPISIDHASH" in raw


def test_load_client_states(config_dir):
    client, state = auth.load_client(factory=FakeClient)
    assert state == "none" and client.path is None

    def broken(path=None):
        if path:
            raise ValueError("bad file")
        return FakeClient()

    config_dir.mkdir(parents=True)
    (config_dir / "browser.json").write_text("{}")
    assert auth.load_client(factory=broken)[1] == "invalid"
    assert auth.load_client(factory=FakeClient)[1] == "ok"


def test_load_client_remembers_visitor_id(config_dir):
    config_dir.mkdir(parents=True)
    path = config_dir / "browser.json"
    path.write_text(json.dumps({"cookie": "SID=a"}))
    assert auth.load_client(factory=VisitorClient)[1] == "ok"
    assert json.loads(path.read_text())["x-goog-visitor-id"] == "VISITOR"
    assert mode(path) == 0o600
    before = path.read_text()
    auth.load_client(factory=VisitorClient)
    assert path.read_text() == before


def test_sign_in_saves_visitor_id(config_dir, monkeypatch):
    fake_setup(monkeypatch)
    auth.import_from_headers("cookie: SID=a; __Secure-3PAPISID=b\n", factory=VisitorClient)
    assert json.loads((config_dir / "browser.json").read_text())["x-goog-visitor-id"] == "VISITOR"


def test_paste_sign_in_writes_private_files(config_dir, monkeypatch):
    fake_setup(monkeypatch)
    account = auth.import_from_headers("accept: */*\ncookie: SID=abc; __Secure-3PAPISID=def\n", factory=FakeClient)
    assert account["name"] == "Test User" and account["method"] == "headers"
    assert mode(config_dir) == 0o700
    for name in auth.SESSION_FILES:
        assert mode(config_dir / name) == 0o600
    assert "__Secure-3PAPISID\tdef" in (config_dir / "cookies.txt").read_text()
    assert json.loads((config_dir / "account.json").read_text())["handle"] == "@test"
    assert auth.whoami()["name"] == "Test User"
    assert not [p for p in config_dir.iterdir() if p.name.startswith(".new-")]


def test_rejected_session_keeps_the_old_one(config_dir, monkeypatch):
    fake_setup(monkeypatch)
    auth.import_from_headers("cookie: SID=old; __Secure-3PAPISID=old\n", factory=FakeClient)
    with pytest.raises(auth.AuthError):
        auth.import_from_headers("cookie: SID=new; __Secure-3PAPISID=new\n", factory=RejectingClient)
    assert "SID=old" in (config_dir / "browser.json").read_text()
    assert not [p for p in config_dir.iterdir() if p.name.startswith(".new-")]


def test_headers_without_cookie_are_refused(config_dir):
    with pytest.raises(auth.AuthError):
        auth.import_from_headers("accept: */*\n")


def test_browser_import(config_dir, monkeypatch, tmp_path):
    fake_setup(monkeypatch)
    profile = tmp_path / "Default"
    profile.mkdir()

    def cookie(domain, name, value):
        return SimpleNamespace(domain=domain, name=name, value=value, path="/", secure=True, expires=1900000000)

    jar = [cookie(".youtube.com", "SID", "abc"), cookie(".youtube.com", "__Secure-3PAPISID", "def"),
           cookie(".google.com", "NID", "g"), cookie(".example.com", "X", "ignored")]
    seen = {}

    def extractor(browser, profile, logger, keyring):
        seen.update(browser=browser, profile=profile, keyring=keyring)
        return jar

    account = auth.import_from_browser("chromium", str(profile), factory=FakeClient, extractor=extractor)
    assert seen == {"browser": "chromium", "profile": str(profile), "keyring": "GNOMEKEYRING"}
    assert account["method"] == "browser:chromium"
    browser_json = json.loads((config_dir / "browser.json").read_text())
    assert browser_json["cookie"] == "SID=abc; __Secure-3PAPISID=def"
    cookies = (config_dir / "cookies.txt").read_text()
    assert ".google.com\tTRUE" in cookies and "example.com" not in cookies


def test_browser_import_needs_signed_in_profile(config_dir, tmp_path):
    def extractor(browser, profile, logger, keyring):
        return [SimpleNamespace(domain=".youtube.com", name="PREF", value="x", path="/", secure=True, expires=0)]

    with pytest.raises(auth.AuthError, match="not signed in"):
        auth.import_from_browser("chromium", str(tmp_path), factory=FakeClient, extractor=extractor)


def test_logout_removes_session(config_dir, monkeypatch):
    fake_setup(monkeypatch)
    auth.import_from_headers("cookie: SID=a; __Secure-3PAPISID=b\n", factory=FakeClient)
    assert sorted(auth.logout()) == sorted(auth.SESSION_FILES)
    assert auth.whoami() is None
    assert auth.logout() == []
