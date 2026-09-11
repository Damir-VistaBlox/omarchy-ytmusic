import pytest

import ytm
import ytm_streams as streams


class FakeYDL:
    created = 0

    def __init__(self, opts, info=None, error=None):
        FakeYDL.created += 1
        self.opts = opts
        self.info = info
        self.error = error
        self.calls = []

    def extract_info(self, url, download=True):
        self.calls.append((url, download))
        if self.error:
            raise self.error
        return self.info


def factory(info=None, error=None):
    made = []

    def make(opts):
        ydl = FakeYDL(opts, info, error)
        made.append(ydl)
        return ydl

    make.made = made
    return make


def test_parse_expiry():
    assert streams.parse_expiry("https://rr1.googlevideo.com/videoplayback?expire=1789100000&id=x") == 1789100000
    assert streams.parse_expiry("https://rr1.googlevideo.com/videoplayback/expire/1789100001/id/x") == 1789100001
    assert streams.parse_expiry("https://example.com/audio", now=1000) == 1000 + streams.DEFAULT_LIFETIME


def test_resolve_returns_url_and_expiry_and_reuses_one_instance():
    make = factory(info={"url": "https://g.googlevideo.com/v?expire=1789100000", "format_id": "251",
                         "acodec": "opus", "abr": 131.4})
    resolver = streams.Resolver(factory=make)
    first = resolver.resolve("abcdefghijk")
    resolver.resolve("bcdefghijkl")
    assert first == {"videoId": "abcdefghijk", "url": "https://g.googlevideo.com/v?expire=1789100000",
                     "expires": 1789100000, "format": "251", "codec": "opus", "abr": 131.4}
    assert len(make.made) == 1, "yt-dlp is created once per worker"
    ydl = make.made[0]
    assert ydl.calls == [("https://www.youtube.com/watch?v=abcdefghijk", False),
                         ("https://www.youtube.com/watch?v=bcdefghijkl", False)]
    assert ydl.opts["format"] == streams.FORMAT and ydl.opts["skip_download"]


def test_requested_formats_fallback_and_missing_url():
    resolver = streams.Resolver(factory=factory(info={"requested_formats": [{"url": "https://x/a?expire=5"}]}))
    assert resolver.resolve("v")["url"] == "https://x/a?expire=5"
    with pytest.raises(streams.StreamError) as err:
        streams.Resolver(factory=factory(info={})).resolve("v")
    assert err.value.code == "UPSTREAM"


@pytest.mark.parametrize("message, code, retryable", [
    ("ERROR: [youtube] abc: Video unavailable", "NOT_FOUND", False),
    ("ERROR: [youtube] abc: Private video. Sign in", "NOT_FOUND", False),
    ("ERROR: [youtube] abc: Unable to download API page: timed out", "NETWORK", True),
    ("ERROR: [youtube] abc: Some new signature problem", "UPSTREAM", False),
])
def test_errors_are_mapped(message, code, retryable):
    with pytest.raises(streams.StreamError) as err:
        streams.Resolver(factory=factory(error=RuntimeError(message))).resolve("abc")
    assert (err.value.code, err.value.retryable) == (code, retryable)
    assert not err.value.message.startswith("ERROR:")


def test_account_cookies_only_when_opted_in(config_dir, monkeypatch):
    config_dir.mkdir(parents=True)
    (config_dir / "cookies.txt").write_text("# Netscape HTTP Cookie File\n")
    monkeypatch.delenv("YTM_STREAM_WITH_ACCOUNT", raising=False)
    assert "cookiefile" not in streams.Resolver().options()
    monkeypatch.setenv("YTM_STREAM_WITH_ACCOUNT", "1")
    assert streams.Resolver().options()["cookiefile"] == str(config_dir / "cookies.txt")


class FakeResolver:
    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error

    def resolve(self, video_id):
        if self.error:
            raise self.error
        return dict(self.result, videoId=video_id)


def test_warm_loads_ytdlp_once_in_the_background():
    make = factory(info={"url": "https://x/a?expire=5"})
    resolver = streams.Resolver(factory=make)
    worker = ytm.Worker(object(), "none", resolver=resolver)
    assert worker.handle({"id": 1, "method": "warmStreams"})["ok"]
    assert worker.handle({"id": 2, "method": "warmStreams"})["ok"]
    assert worker.handle({"id": 3, "method": "resolve", "params": {"videoId": "v"}})["ok"]
    assert len(make.made) == 1, "warm-up and resolve share one yt-dlp instance"


def test_warm_is_harmless_without_warm_support():
    worker = ytm.Worker(object(), "none", resolver=FakeResolver({"url": "https://x", "expires": 5}))
    assert worker.handle({"id": 1, "method": "warmStreams"})["ok"]


def test_worker_resolve_method():
    worker = ytm.Worker(object(), "none", resolver=FakeResolver({"url": "https://x", "expires": 5}))
    reply = worker.handle({"id": 1, "method": "resolve", "params": {"videoId": "abc"}})
    assert reply["ok"] and reply["result"]["videoId"] == "abc" and reply["result"]["url"] == "https://x"
    failing = ytm.Worker(object(), "none", resolver=FakeResolver(error=streams.StreamError("NETWORK", "offline", True)))
    error = failing.handle({"id": 2, "method": "resolve", "params": {"videoId": "abc"}})["error"]
    assert (error["code"], error["retryable"]) == ("NETWORK", True)
    assert worker.handle({"id": 3, "method": "resolve", "params": {}})["error"]["code"] == "BAD_REQUEST"
