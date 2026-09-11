"""Resolve playable audio stream URLs with yt-dlp inside the long-running
worker, so each track skips yt-dlp's start-up and reuses its player cache
(measured: ~1.0-1.4 s warm vs ~2 s for a fresh yt-dlp per track).

mpv plays the returned URL through mpv/ytm-streams.lua while its playlist
keeps the youtube.com URL. Stream URLs expire (YouTube puts the time in the
URL) and are tied to this network; the Lua script falls back to yt-dlp when
one fails. Like mpv, this streams without the account unless
YTM_STREAM_WITH_ACCOUNT=1.
"""

import os
import re
import threading
import time

import ytm_auth as auth
import ytm_normalize as norm

FORMAT = "bestaudio[acodec=opus]/bestaudio/best"
WATCH_URL = "https://www.youtube.com/watch?v="
DEFAULT_LIFETIME = 5 * 3600
_EXPIRE = re.compile(r"[?&/]expire[=/](\d+)")


class StreamError(Exception):
    def __init__(self, code, message, retryable=False):
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable


def parse_expiry(url, now=None):
    match = _EXPIRE.search(url or "")
    if match:
        return int(match.group(1))
    return int((now if now is not None else time.time()) + DEFAULT_LIFETIME)


def stream_with_account():
    return os.environ.get("YTM_STREAM_WITH_ACCOUNT") == "1"


class _Quiet:
    def debug(self, message, **kwargs):
        pass

    def info(self, message, **kwargs):
        pass

    def warning(self, message, **kwargs):
        norm.log(f"yt-dlp: {message}")

    def error(self, message, **kwargs):
        pass  # raised as an exception right after; reported from there


def _error(exc):
    message = str(exc).strip().splitlines()[0] if str(exc).strip() else type(exc).__name__
    message = re.sub(r"^ERROR:\s*", "", message)
    lowered = message.lower()
    if any(word in lowered for word in ("unavailable", "private video", "removed", "not available", "members-only")):
        return StreamError("NOT_FOUND", message)
    if any(word in lowered for word in ("unable to download", "timed out", "connection", "network", "temporary failure")):
        return StreamError("NETWORK", message, True)
    return StreamError("UPSTREAM", message)


class Resolver:
    """One yt-dlp instance for the worker's lifetime (imported on first use)."""

    def __init__(self, factory=None):
        self._factory = factory
        self._ydl = None
        # The warm-up thread and the worker's streams lane may both get here
        # first; lookups themselves only ever run on the lane.
        self._lock = threading.Lock()

    def options(self):
        opts = {
            "format": FORMAT,
            "quiet": True,
            "no_warnings": True,
            "skip_download": True,
            "noplaylist": True,
            "logger": _Quiet(),
        }
        cookies = auth.cookies_path()
        if stream_with_account() and cookies.exists():
            opts["cookiefile"] = str(cookies)
        return opts

    def _client(self):
        with self._lock:
            if self._ydl is None:
                if self._factory is None:
                    import yt_dlp

                    self._ydl = yt_dlp.YoutubeDL(self.options())
                else:
                    self._ydl = self._factory(self.options())
            return self._ydl

    def warm(self):
        try:
            self._client()
        except Exception as exc:  # noqa: BLE001 - resolve() reports it properly later
            norm.log(f"could not load yt-dlp: {type(exc).__name__}: {exc}")

    def resolve(self, video_id):
        try:
            info = self._client().extract_info(WATCH_URL + video_id, download=False)
        except Exception as exc:  # noqa: BLE001 - yt-dlp raises DownloadError and friends
            raise _error(exc) from exc
        url = info.get("url")
        if not url:
            requested = info.get("requested_formats") or []
            url = requested[0].get("url") if requested else None
        if not url:
            raise StreamError("UPSTREAM", "YouTube returned no playable audio stream")
        return {
            "videoId": video_id,
            "url": url,
            "expires": parse_expiry(url),
            "format": info.get("format_id"),
            "codec": info.get("acodec"),
            "abr": info.get("abr"),
        }
