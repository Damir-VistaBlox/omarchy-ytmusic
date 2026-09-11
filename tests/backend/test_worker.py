import json
import os
import subprocess
import sys
import threading
import time

import pytest
import requests
from ytmusicapi.exceptions import YTMusicServerError, YTMusicUserError

import ytm
from conftest import ROOT


class FakeYT:
    def __init__(self, **responses):
        self.responses = responses
        self.calls = []

    def __getattr__(self, name):
        def method(*args, **kwargs):
            self.calls.append((name, args, kwargs))
            value = self.responses.get(name)
            if isinstance(value, Exception):
                raise value
            return value

        return method


def call(worker, method, **params):
    return worker.handle({"id": 7, "method": method, "params": params})


def test_ping_and_unknown_method():
    worker = ytm.Worker(FakeYT(), "none")
    assert call(worker, "ping") == {"id": 7, "ok": True, "result": {"pong": True}, "ms": call(worker, "ping")["ms"]}
    reply = call(worker, "nope")
    assert reply["ok"] is False and reply["error"]["code"] == "BAD_REQUEST"


def test_bad_params_are_bad_request():
    worker = ytm.Worker(FakeYT(search=[]), "none")
    assert call(worker, "search")["error"]["code"] == "BAD_REQUEST"
    assert call(worker, "search", query="x", filter="podcasts")["error"]["code"] == "BAD_REQUEST"
    assert call(worker, "search", query="x", limit="many")["error"]["code"] == "BAD_REQUEST"
    assert worker.handle({"id": 1, "method": "search", "params": []})["error"]["code"] == "BAD_REQUEST"
    assert worker.handle("not an object")["error"]["code"] == "BAD_REQUEST"


def test_session_is_verified_once():
    fake = FakeYT(get_account_info={"accountName": "x"}, get_library_playlists=[])
    worker = ytm.Worker(fake, "ok")
    assert call(worker, "libraryPlaylists")["ok"]
    assert call(worker, "libraryPlaylists")["ok"]
    assert [c[0] for c in fake.calls].count("get_account_info") == 1


def test_expired_session_is_detected_by_account_lookup(config_dir):
    fake = FakeYT(get_account_info=KeyError("header"), get_library_playlists=[])
    worker = ytm.Worker(fake, "ok")
    assert call(worker, "libraryPlaylists")["error"]["code"] == "AUTH_EXPIRED"
    assert call(worker, "liked")["error"]["code"] == "AUTH_EXPIRED"
    names = [c[0] for c in fake.calls]
    assert names.count("get_account_info") == 1 and "get_library_playlists" not in names
    assert call(worker, "hello")["result"]["auth"] == "expired"
    assert call(worker, "search", query="x", filter="songs")["ok"]  # signed-out features keep working


def test_offline_verification_does_not_mark_expired():
    worker = ytm.Worker(FakeYT(get_account_info=requests.exceptions.ConnectionError("down")), "ok")
    assert call(worker, "libraryPlaylists")["error"]["code"] == "NETWORK"
    assert worker.auth == "ok"


def test_http_401_marks_session_expired():
    worker = ytm.Worker(FakeYT(get_library_playlists=YTMusicServerError("Server returned HTTP 401: Unauthorized.")), "ok")
    assert call(worker, "libraryPlaylists")["error"]["code"] == "AUTH_EXPIRED"
    assert worker.auth == "expired"


def test_verify_auth_method(config_dir):
    assert call(ytm.Worker(FakeYT(get_account_info=KeyError("x")), "ok"), "verifyAuth")["result"]["auth"] == "expired"
    assert call(ytm.Worker(FakeYT(), "ok"), "verifyAuth")["result"]["auth"] == "ok"
    assert call(ytm.Worker(FakeYT(), "none"), "verifyAuth")["result"]["auth"] == "none"


def test_library_needs_auth():
    worker = ytm.Worker(FakeYT(get_library_playlists=[]), "none")
    assert call(worker, "libraryPlaylists")["error"]["code"] == "AUTH_REQUIRED"
    assert call(worker, "rate", videoId="v", rating="LIKE")["error"]["code"] == "AUTH_REQUIRED"


@pytest.mark.parametrize("exc, code, retryable", [
    (YTMusicServerError("Server returned HTTP 401: Unauthorized.\nx"), "AUTH_EXPIRED", False),
    (YTMusicServerError("Server returned HTTP 403: Forbidden."), "AUTH_EXPIRED", False),
    (YTMusicServerError("Server returned HTTP 429: Too Many Requests."), "RATE_LIMITED", True),
    (YTMusicServerError("Server returned HTTP 404: Not Found."), "NOT_FOUND", False),
    (YTMusicServerError("Server returned HTTP 500: oops"), "UPSTREAM", False),
    (YTMusicUserError("Please provide authentication before using this function"), "AUTH_REQUIRED", False),
    (requests.exceptions.ConnectionError("down"), "NETWORK", True),
    (requests.exceptions.ReadTimeout("slow"), "NETWORK", True),
    (KeyError("contents"), "UPSTREAM", False),
    (RuntimeError("boom"), "INTERNAL", False),
])
def test_errors_are_classified(exc, code, retryable):
    worker = ytm.Worker(FakeYT(search=exc), "ok")
    error = call(worker, "search", query="x", filter="songs")["error"]
    assert (error["code"], error["retryable"]) == (code, retryable)
    assert error["message"]


def test_search_filtered_and_grouped():
    songs = [{"resultType": "song", "videoId": "a", "title": "A", "duration": "1:00"}]
    worker = ytm.Worker(FakeYT(search=songs), "none")
    assert [t["videoId"] for t in call(worker, "search", query="x", filter="songs")["result"]["items"]] == ["a"]
    grouped = call(worker, "search", query="x")["result"]
    assert [t["videoId"] for t in grouped["songs"]] == ["a"]


def test_suggestions_keep_text_and_history_flag():
    fake = FakeYT(get_search_suggestions=[{"text": "daft punk", "fromHistory": True, "runs": []},
                                          {"text": " daft punk get lucky "}, "plain", {"text": ""}])
    result = call(ytm.Worker(fake, "none"), "suggestions", query="daft p")["result"]
    assert result == {"items": [{"text": "daft punk", "fromHistory": True},
                                {"text": "daft punk get lucky", "fromHistory": False},
                                {"text": "plain", "fromHistory": False}]}
    assert fake.calls[-1] == ("get_search_suggestions", ("daft p",), {"detailed_runs": True})
    assert call(ytm.Worker(fake, "none"), "suggestions", query=" ")["error"]["code"] == "BAD_REQUEST"


def test_rate_passes_like_status_enum():
    fake = FakeYT(rate_song={})
    worker = ytm.Worker(fake, "ok")
    assert call(worker, "rate", videoId="v", rating="LIKE")["result"] == {"videoId": "v", "likeStatus": "LIKE"}
    name, args, _ = fake.calls[-1]
    assert name == "rate_song" and args[0] == "v" and args[1].name == "LIKE"
    assert call(worker, "rate", videoId="v", rating="LOVE")["error"]["code"] == "BAD_REQUEST"


def test_playlist_edits():
    fake = FakeYT(
        create_playlist="PLnew",
        add_playlist_items={"status": "STATUS_SUCCEEDED",
                            "playlistEditResults": [{"videoId": "a", "setVideoId": "S1"}]},
        remove_playlist_items="STATUS_SUCCEEDED",
        delete_playlist="STATUS_SUCCEEDED",
    )
    worker = ytm.Worker(fake, "ok")
    assert call(worker, "createPlaylist", title="ytm-test")["result"] == {"playlistId": "PLnew"}
    assert call(worker, "addToPlaylist", playlistId="PLnew", videoIds=["a"])["result"] == \
        {"added": [{"videoId": "a", "setVideoId": "S1"}]}
    assert call(worker, "removeFromPlaylist", playlistId="PLnew",
                items=[{"videoId": "a", "setVideoId": "S1"}])["result"] == {"ok": True}
    assert call(worker, "removeFromPlaylist", playlistId="PLnew", items=[{"videoId": "a"}])["error"]["code"] == "BAD_REQUEST"
    assert call(worker, "deletePlaylist", playlistId="PLnew")["result"] == {"ok": True}


@pytest.mark.parametrize("response, ok", [
    ("STATUS_SUCCEEDED", True),
    ({"responseContext": {}}, True),  # what a successful delete actually returns (no status)
    ("STATUS_FAILED", False),
    ({"error": {"code": 400}}, False),
])
def test_delete_playlist_responses(response, ok):
    reply = call(ytm.Worker(FakeYT(delete_playlist=response), "ok"), "deletePlaylist", playlistId="PLx")
    assert reply["ok"] is ok
    if not ok:
        assert reply["error"]["code"] == "UPSTREAM"


def test_failed_edits_are_upstream_errors():
    worker = ytm.Worker(FakeYT(add_playlist_items={"status": "STATUS_FAILED"}, create_playlist={"error": 1}), "ok")
    assert call(worker, "addToPlaylist", playlistId="P", videoIds=["a"])["error"]["code"] == "UPSTREAM"
    assert call(worker, "createPlaylist", title="t")["error"]["code"] == "UPSTREAM"


def test_up_next_drops_the_seed_and_normalizes():
    watch = json.loads((ROOT / "tests" / "fixtures" / "watch.json").read_text())
    seed = watch["tracks"][0]["videoId"]
    fake = FakeYT(get_watch_playlist=watch)
    result = call(ytm.Worker(fake, "none"), "upNext", videoId=seed)["result"]
    assert result["items"] and all(t["videoId"] != seed for t in result["items"])
    assert all(t["type"] == "track" and t["title"] and t["thumb"] for t in result["items"])
    assert fake.calls[-1][2] == {"videoId": seed, "limit": 25}
    assert call(ytm.Worker(fake, "none"), "upNext")["error"]["code"] == "BAD_REQUEST"


def test_like_status_picks_matching_track():
    fake = FakeYT(get_watch_playlist={"tracks": [{"videoId": "v", "likeStatus": "LIKE"}]})
    assert call(ytm.Worker(fake, "ok"), "likeStatus", videoId="v")["result"] == {"videoId": "v", "likeStatus": "LIKE"}


# ---- the real serve loop, as the shell drives it ----------------------------


def spawn(config_dir, *args):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONUNBUFFERED="1", YTM_CONFIG_DIR=str(config_dir))
    return subprocess.Popen([sys.executable, str(ROOT / "backend" / "ytm.py"), "serve", *args],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=env)


def test_serve_protocol_and_eof_exit(config_dir):
    proc = spawn(config_dir, "--idle", "30")
    ready = json.loads(proc.stdout.readline())
    assert ready["event"] == "ready" and ready["protocol"] == 1 and ready["auth"] == "none"
    proc.stdin.write('{"id":1,"method":"ping"}\nnot json\n{"id":2,"method":"hello"}\n')
    proc.stdin.flush()
    replies = [json.loads(proc.stdout.readline()) for _ in range(3)]
    assert replies[0]["id"] == 1 and replies[0]["result"] == {"pong": True}
    assert replies[1]["error"]["code"] == "BAD_REQUEST"
    assert replies[2]["result"] == {"auth": "none", "account": None}
    started = time.monotonic()
    proc.stdin.close()
    assert proc.wait(timeout=5) == 0
    assert time.monotonic() - started < 1.0
    assert proc.stdout.read() == ""  # nothing but protocol lines on stdout


def test_serve_idle_exit(config_dir):
    proc = spawn(config_dir, "--idle", "0.3")
    assert json.loads(proc.stdout.readline())["event"] == "ready"
    assert json.loads(proc.stdout.readline()) == {"event": "idle-exit"}
    assert proc.wait(timeout=5) == 0


def test_stream_lookups_do_not_hold_up_other_requests():
    class SlowResolver:
        def resolve(self, video_id):
            time.sleep(0.4)
            return {"url": "https://example.com/" + video_id, "expires": 1}

    class Out:
        def __init__(self):
            self.lines = []

        def write(self, text):
            self.lines.append(json.loads(text))

        def flush(self):
            pass

    out = Out()
    read_fd, write_fd = os.pipe()
    worker = ytm.Worker(FakeYT(), "none", resolver=SlowResolver())
    thread = threading.Thread(target=ytm.serve, args=(5,), kwargs={"worker": worker, "stdin_fd": read_fd, "out": out},
                              daemon=True)
    thread.start()
    os.write(write_fd, b'{"id":1,"method":"resolve","params":{"videoId":"abcdefghijk"}}\n'
                       b'{"id":2,"method":"resolve","params":{"videoId":"bcdefghijkl"}}\n'
                       b'{"id":3,"method":"ping"}\n')
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and len(out.lines) < 4:
        time.sleep(0.01)
    replies = [line for line in out.lines if "id" in line]
    assert [r["id"] for r in replies] == [3, 1, 2], "ping answered first; lookups one at a time, in order"
    assert replies[1]["result"]["url"].endswith("abcdefghijk")
    os.close(write_fd)
    thread.join(timeout=5)
    assert not thread.is_alive()
    os.close(read_fd)


def test_serve_shutdown(config_dir):
    proc = spawn(config_dir)
    proc.stdout.readline()
    proc.stdin.write('{"id":9,"method":"shutdown"}\n')
    proc.stdin.flush()
    assert json.loads(proc.stdout.readline())["id"] == 9
    assert proc.wait(timeout=5) == 0
