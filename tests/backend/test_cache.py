import json
import stat
import time

import pytest

import ytm
import ytm_cache as caches


def mode(path):
    return stat.S_IMODE(path.stat().st_mode)


@pytest.fixture
def cache(tmp_path):
    return caches.DiskCache(tmp_path / "data")


def test_put_get_age_and_private_files(cache):
    cache.put("playlist", {"playlistId": "P1", "limit": 200}, {"title": "Mine"}, now=1000)
    assert cache.get("playlist", {"limit": 200, "playlistId": "P1"}, now=1060) == ({"title": "Mine"}, 60)
    assert cache.get("playlist", {"playlistId": "P2", "limit": 200}, now=1060) is None
    assert cache.get("playlist", {"playlistId": "P1", "limit": 200}, now=1000 + caches.DiskCache.MAX_AGE + 1) is None
    assert mode(cache.dir) == 0o700
    assert mode(cache.dir.parent) == 0o700, "the cache root holds session.json too"
    assert all(mode(p) == 0o600 for p in cache.dir.iterdir())


def test_invalidate_by_method_and_param(cache):
    cache.put("playlist", {"playlistId": "P1"}, 1)
    cache.put("playlist", {"playlistId": "P2"}, 2)
    cache.put("liked", {}, 3)
    cache.invalidate("playlist", {"playlistId": "P1"})
    assert cache.get("playlist", {"playlistId": "P1"}) is None
    assert cache.get("playlist", {"playlistId": "P2"}) is not None
    cache.invalidate("liked")
    assert cache.get("liked", {}) is None
    cache.clear()
    assert list(cache.dir.glob("*.json")) == []
    caches.DiskCache(cache.dir / "missing").invalidate("liked")  # no directory: nothing to do


def test_corrupt_entries_are_misses(cache):
    cache.put("liked", {}, {"tracks": []})
    path = cache.dir / cache.key("liked", {})
    path.write_text('{"at": 1, "result": ')  # cut off mid-write
    assert cache.get("liked", {}) is None
    worker = ytm.Worker(Upstream(), "ok", cache=cache)
    reply = request(worker, "playlist", playlistId="P", cache="prefer")
    assert reply["ok"] and reply["cached"] is False, "a broken cache never breaks the request"


def test_prune_keeps_the_newest(cache, monkeypatch):
    monkeypatch.setattr(caches.DiskCache, "MAX_FILES", 3)
    for i in range(5):
        cache.put("album", {"browseId": str(i)}, i)
        time.sleep(0.01)
    assert len(list(cache.dir.glob("*.json"))) == 3
    assert cache.get("album", {"browseId": "4"}) is not None
    assert cache.get("album", {"browseId": "0"}) is None


class Upstream:
    def __init__(self):
        self.calls = 0

    def get_playlist(self, playlist_id, limit=200):
        self.calls += 1
        return {"id": playlist_id, "title": f"v{self.calls}", "owned": True, "trackCount": 0, "tracks": []}

    def add_playlist_items(self, playlist_id, video_ids, duplicates=False):
        return {"status": "STATUS_SUCCEEDED", "playlistEditResults": []}

    def get_account_info(self):
        return {"accountName": "x"}


def request(worker, method, **params):
    return worker.handle({"id": 1, "method": method, "params": params})


def test_worker_cache_modes(cache):
    upstream = Upstream()
    worker = ytm.Worker(upstream, "ok", cache=cache)
    first = request(worker, "playlist", playlistId="P", cache="prefer")
    assert first["ok"] and first["cached"] is False and upstream.calls == 1
    again = request(worker, "playlist", playlistId="P", cache="prefer")
    assert again["cached"] is True and again["result"]["title"] == "v1" and upstream.calls == 1
    assert "age" in again
    fresh = request(worker, "playlist", playlistId="P", cache="refresh")
    assert fresh["cached"] is False and fresh["result"]["title"] == "v2" and upstream.calls == 2
    assert request(worker, "playlist", playlistId="P", cache="prefer")["result"]["title"] == "v2"
    plain = request(worker, "playlist", playlistId="P")
    assert plain["result"]["title"] == "v3", "bypass (default) always asks YouTube"
    assert request(worker, "playlist", playlistId="P", cache="sometimes")["error"]["code"] == "BAD_REQUEST"


def test_edits_invalidate_the_cache(cache):
    worker = ytm.Worker(Upstream(), "ok", cache=cache)
    request(worker, "playlist", playlistId="P", cache="prefer")
    cache.put("libraryPlaylists", {"limit": 200}, {"items": []})
    assert request(worker, "addToPlaylist", playlistId="P", videoIds=["v"])["ok"]
    assert cache.get("playlist", {"playlistId": "P"}) is None
    assert cache.get("libraryPlaylists", {"limit": 200}) is None


def test_reload_auth_clears_the_cache(cache, config_dir, monkeypatch):
    cache.put("liked", {}, {"tracks": []})
    worker = ytm.Worker(Upstream(), "ok", cache=cache)
    monkeypatch.setattr(worker, "load", lambda: None)
    assert request(worker, "reloadAuth")["ok"]
    assert cache.get("liked", {}) is None


# ---- thumbnails ----------------------------------------------------------------


def test_thumb_hosts_are_restricted():
    assert caches.ThumbCache.allowed("https://lh3.googleusercontent.com/a=w120")
    assert caches.ThumbCache.allowed("https://i.ytimg.com/vi/x/hqdefault.jpg")
    assert caches.ThumbCache.allowed("https://yt3.ggpht.com/x=s88")
    assert not caches.ThumbCache.allowed("http://lh3.googleusercontent.com/a")
    assert not caches.ThumbCache.allowed("https://evil.example.com/googleusercontent.com.jpg")
    assert not caches.ThumbCache.allowed("file:///etc/passwd")


def test_thumb_fetch_downloads_once_and_prunes(tmp_path, monkeypatch):
    downloads = []

    def downloader(url):
        downloads.append(url)
        return None if "broken" in url else b"x" * 100

    thumbs = caches.ThumbCache(tmp_path / "thumbs", downloader=downloader)
    urls = ["https://i.ytimg.com/a.jpg", "https://i.ytimg.com/broken.jpg", "https://example.com/x.jpg"]
    got = thumbs.fetch(urls)
    assert set(got) == {"https://i.ytimg.com/a.jpg"}
    assert mode(tmp_path / "thumbs") == 0o700
    assert thumbs.fetch(urls) == got
    assert downloads.count("https://i.ytimg.com/a.jpg") == 1, "cached files are not downloaded again"
    monkeypatch.setattr(caches.ThumbCache, "MAX_BYTES", 150)
    thumbs.fetch(["https://i.ytimg.com/b.jpg"])
    assert len(list((tmp_path / "thumbs").glob("*.img"))) == 1


def test_cache_thumbs_method_sync_and_background(tmp_path):
    thumbs = caches.ThumbCache(tmp_path / "thumbs", downloader=lambda url: b"img")
    worker = ytm.Worker(Upstream(), "ok", thumbs=thumbs)
    reply = request(worker, "cacheThumbs", urls=["https://i.ytimg.com/a.jpg"])
    assert list(reply["result"]["paths"]) == ["https://i.ytimg.com/a.jpg"] and reply["result"]["pending"] == 0
    events = []
    worker.emit = events.append
    reply = request(worker, "cacheThumbs", urls=["https://i.ytimg.com/a.jpg", "https://i.ytimg.com/c.jpg"])
    assert list(reply["result"]["paths"]) == ["https://i.ytimg.com/a.jpg"]
    assert reply["result"]["pending"] == 1
    for _ in range(100):
        if events:
            break
        time.sleep(0.01)
    assert events and list(events[0]["paths"]) == ["https://i.ytimg.com/c.jpg"]
    assert request(worker, "cacheThumbs", urls="nope")["error"]["code"] == "BAD_REQUEST"


def test_serve_reports_background_thumbs_as_events(config_dir, tmp_path, monkeypatch):
    import os
    import subprocess
    import sys

    from conftest import ROOT

    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", YTM_CONFIG_DIR=str(config_dir),
               YTM_CACHE_DIR=str(tmp_path / "cache"))
    proc = subprocess.Popen([sys.executable, str(ROOT / "backend" / "ytm.py"), "serve", "--idle", "10"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
    assert json.loads(proc.stdout.readline())["event"] == "ready"
    proc.stdin.write('{"id":1,"method":"cacheThumbs","params":{"urls":["https://example.com/not-allowed.jpg"]}}\n')
    proc.stdin.flush()
    reply = json.loads(proc.stdout.readline())
    assert reply["ok"] and reply["result"] == {"paths": {}, "pending": 0}
    proc.stdin.close()
    assert proc.wait(timeout=5) == 0
