#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "ytmusicapi==1.12.2",
#   "yt-dlp",
#   "secretstorage",
# ]
# ///
"""damir.ytmusic backend: ytmusicapi behind a JSON-lines worker and a CLI.

The shell runs ``ytm.py serve``: one JSON request per stdin line, one JSON
reply per stdout line. It exits on stdin EOF (so it can never outlive the
shell) or after ``--idle`` seconds without requests (so it costs nothing when
you are not browsing).

    request  {"id": 1, "method": "search", "params": {"query": "..."}}
    success  {"id": 1, "ok": true, "result": {...}, "ms": 612}
    failure  {"id": 1, "ok": false, "error": {"code": "...", "message": "...", "retryable": false}}
    events   {"event": "ready", ...}  {"event": "idle-exit"}
"""

import sys

# The plugin directory is watched by the shell; a __pycache__ appearing there
# would trigger plugin reloads.
sys.dont_write_bytecode = True

import argparse  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import queue  # noqa: E402
import select  # noqa: E402
import subprocess  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import traceback  # noqa: E402

import ytm_auth as auth  # noqa: E402
import ytm_cache as caches  # noqa: E402
import ytm_normalize as norm  # noqa: E402
import ytm_streams as streams  # noqa: E402

PROTOCOL = 1
VERSION = "1.0.0"
SEARCH_FILTERS = ("songs", "videos", "albums", "artists", "playlists", "community_playlists", "featured_playlists")
RATINGS = ("LIKE", "DISLIKE", "INDIFFERENT")
PRIVACY = ("PRIVATE", "UNLISTED", "PUBLIC")

# Responses kept in the disk cache. Requests pick a mode with params.cache:
# "prefer" answers from disk when possible (reply has cached/age), "refresh"
# always asks YouTube and stores the answer, "bypass" (default) neither.
CACHEABLE = {"libraryPlaylists", "liked", "playlist", "album", "artist", "home", "history"}
# Methods answered on a background thread ("lane") so they never hold up the
# requests behind them: a stream lookup takes ~1 s, and completions must show
# while a search is still running. A lane handles its own requests one at a
# time, in order; replies carry the request id, so they may overtake each
# other. (ytmusicapi's requests session is shared with the suggest lane;
# requests' connection pool and cookie jar are thread-safe.)
LANES = {"resolve": "streams", "suggestions": "suggest"}
CACHE_MODES = ("prefer", "refresh", "bypass")
# What an edit makes stale: (method, param to match or None for all).
INVALIDATES = {
    "rate": [("liked", None)],
    "addToPlaylist": [("playlist", "playlistId"), ("libraryPlaylists", None)],
    "removeFromPlaylist": [("playlist", "playlistId"), ("libraryPlaylists", None)],
    "createPlaylist": [("libraryPlaylists", None)],
    "deletePlaylist": [("playlist", "playlistId"), ("libraryPlaylists", None)],
}


class WorkerError(Exception):
    def __init__(self, code, message, retryable=False):
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable

    def as_dict(self):
        return {"code": self.code, "message": self.message, "retryable": self.retryable}


def classify(exc):
    """Map any exception to a WorkerError with one of the protocol's codes."""
    if isinstance(exc, WorkerError):
        return exc
    from ytmusicapi.exceptions import YTMusicServerError, YTMusicUserError

    message = str(exc).strip().splitlines()[0] if str(exc).strip() else type(exc).__name__
    if isinstance(exc, YTMusicServerError):
        if "HTTP 401" in message or "HTTP 403" in message:
            return WorkerError("AUTH_EXPIRED", "YouTube Music rejected the saved session; sign in again")
        if "HTTP 429" in message:
            return WorkerError("RATE_LIMITED", "YouTube Music is rate limiting requests", True)
        if "HTTP 404" in message:
            return WorkerError("NOT_FOUND", "Not found on YouTube Music")
        return WorkerError("UPSTREAM", message)
    if isinstance(exc, YTMusicUserError):
        if "authentication" in message.lower():
            return WorkerError("AUTH_REQUIRED", "Sign in to use your library")
        return WorkerError("BAD_REQUEST", message)
    try:
        import requests

        if isinstance(exc, (requests.exceptions.ConnectionError, requests.exceptions.Timeout)):
            return WorkerError("NETWORK", "Could not reach YouTube Music", True)
    except ImportError:
        pass
    if isinstance(exc, (KeyError, TypeError, IndexError, AttributeError, json.JSONDecodeError)):
        return WorkerError("UPSTREAM", "Unexpected response from YouTube Music (ytmusicapi may need an update)")
    return WorkerError("INTERNAL", f"{type(exc).__name__}: {message}")


# ---- parameter helpers --------------------------------------------------------


def req_str(params, key):
    value = params.get(key)
    if not isinstance(value, str) or not value.strip():
        raise WorkerError("BAD_REQUEST", f"missing or empty '{key}'")
    return value.strip()


def opt_int(params, key, default, low=1, high=1000):
    value = params.get(key, default)
    if value is None:
        return default
    if isinstance(value, bool) or not isinstance(value, int):
        raise WorkerError("BAD_REQUEST", f"'{key}' must be an integer")
    return max(low, min(high, value))


def req_list(params, key):
    value = params.get(key)
    if not isinstance(value, list) or not value:
        raise WorkerError("BAD_REQUEST", f"'{key}' must be a non-empty list")
    return value


def choice(params, key, options, default=None):
    value = params.get(key, default)
    if value is None or value in options:
        return value
    raise WorkerError("BAD_REQUEST", f"'{key}' must be one of {', '.join(options)}")


def _succeeded(result):
    status = result.get("status") if isinstance(result, dict) else result
    return status == "STATUS_SUCCEEDED"


# ---- methods ------------------------------------------------------------------


def m_ping(worker, params):
    return {"pong": True}


def m_hello(worker, params):
    return {"auth": worker.auth, "account": auth.whoami()}


def m_reload_auth(worker, params):
    worker.load()
    worker.clear_cache()
    return m_hello(worker, params)


def m_cache_thumbs(worker, params):
    urls = params.get("urls")
    if not isinstance(urls, list) or any(not isinstance(u, str) for u in urls):
        raise WorkerError("BAD_REQUEST", "'urls' must be a list of strings")
    thumbs = worker.thumbs()
    urls = urls[:200]
    have = thumbs.cached(urls)
    missing = [u for u in urls if u not in have and thumbs.allowed(u)]
    if missing and worker.emit is None:
        have.update(thumbs.fetch(missing))
        missing = []
    elif missing:
        # Downloads must not hold up searches queued behind this request; the
        # new paths follow as a {"event": "thumbs"} line.
        def download():
            got = thumbs.fetch(missing)
            if got:
                worker.emit({"event": "thumbs", "paths": got})

        threading.Thread(target=download, daemon=True).start()
    return {"paths": have, "pending": len(missing)}


def m_verify_auth(worker, params):
    worker.verify_session()
    return m_hello(worker, params)


def m_search(worker, params):
    query = req_str(params, "query")
    search_filter = choice(params, "filter", SEARCH_FILTERS)
    limit = opt_int(params, "limit", 20, high=100)
    if search_filter:
        results = worker.yt.search(query, filter=search_filter, limit=limit)
        return {"items": norm.normalize_list(results, norm.search_item, "search result")}
    return norm.search_grouped(worker.yt.search(query, limit=limit))


def m_suggestions(worker, params):
    """Completions for a half-typed search (with your own searches when signed in)."""
    query = req_str(params, "query")
    limit = opt_int(params, "limit", 8, high=20)
    items = []
    for raw in worker.yt.get_search_suggestions(query, detailed_runs=True) or []:
        text = raw.get("text") if isinstance(raw, dict) else raw
        if isinstance(text, str) and text.strip():
            items.append({"text": text.strip(), "fromHistory": bool(isinstance(raw, dict) and raw.get("fromHistory"))})
    return {"items": items[:limit]}


def m_home(worker, params):
    return {"shelves": norm.home(worker.yt.get_home(limit=opt_int(params, "limit", 6, high=20)))}


def m_history(worker, params):
    worker.require_auth()
    limit = opt_int(params, "limit", 100, high=200)
    return {"items": norm.normalize_list(worker.yt.get_history()[:limit], norm.track, "history item")}


def m_library_playlists(worker, params):
    worker.require_auth()
    items = worker.yt.get_library_playlists(limit=opt_int(params, "limit", 100, high=500))
    return {"items": norm.normalize_list(items, norm.playlist, "library playlist")}


def m_playlist(worker, params):
    playlist_id = req_str(params, "playlistId")
    data = worker.yt.get_playlist(playlist_id, limit=opt_int(params, "limit", 200, high=5000))
    return norm.collection("playlist", data, playlist_id)


def m_liked(worker, params):
    worker.require_auth()
    data = worker.yt.get_liked_songs(limit=opt_int(params, "limit", 200, high=5000))
    return norm.collection("liked", data, "LM")


def m_album(worker, params):
    browse_id = req_str(params, "browseId")
    return norm.collection("album", worker.yt.get_album(browse_id), browse_id)


def m_artist(worker, params):
    channel_id = req_str(params, "channelId")
    return norm.artist_page(channel_id, worker.yt.get_artist(channel_id))


def m_song(worker, params):
    return norm.song(worker.yt.get_song(req_str(params, "videoId")))


def m_warm_streams(worker, params):
    worker.warm_resolver()
    return {"ok": True}


def m_resolve(worker, params):
    video_id = req_str(params, "videoId")
    worker.wait_for_warm()
    try:
        return worker.resolver().resolve(video_id)
    except streams.StreamError as exc:
        raise WorkerError(exc.code, exc.message, exc.retryable) from exc


def m_up_next(worker, params):
    """What YouTube Music would play after ``videoId`` (autoplay), without it."""
    video_id = req_str(params, "videoId")
    data = worker.yt.get_watch_playlist(videoId=video_id, limit=opt_int(params, "limit", 25, high=100))
    tracks = norm.normalize_list(data.get("tracks"), norm.track, "up-next track")
    return {"playlistId": data.get("playlistId"), "items": [t for t in tracks if t["videoId"] != video_id]}


def m_like_status(worker, params):
    worker.require_auth()
    video_id = req_str(params, "videoId")
    tracks = worker.yt.get_watch_playlist(videoId=video_id, limit=1).get("tracks") or []
    match = next((t for t in tracks if t.get("videoId") == video_id), tracks[0] if tracks else {})
    return {"videoId": video_id, "likeStatus": norm.like_status(match.get("likeStatus"))}


def m_rate(worker, params):
    worker.require_auth()
    from ytmusicapi.models.content.enums import LikeStatus

    video_id = req_str(params, "videoId")
    rating = choice(params, "rating", RATINGS)
    if rating is None:
        raise WorkerError("BAD_REQUEST", "missing 'rating'")
    worker.yt.rate_song(video_id, LikeStatus[rating])
    return {"videoId": video_id, "likeStatus": rating}


def m_create_playlist(worker, params):
    worker.require_auth()
    title = req_str(params, "title")
    description = params.get("description") or ""
    privacy = choice(params, "privacy", PRIVACY, "PRIVATE")
    video_ids = params.get("videoIds") or None
    result = worker.yt.create_playlist(title, description, privacy_status=privacy, video_ids=video_ids)
    if isinstance(result, str):
        return {"playlistId": result}
    raise WorkerError("UPSTREAM", "YouTube Music did not create the playlist")


def m_add_to_playlist(worker, params):
    worker.require_auth()
    playlist_id = req_str(params, "playlistId")
    video_ids = req_list(params, "videoIds")
    result = worker.yt.add_playlist_items(playlist_id, video_ids, duplicates=bool(params.get("duplicates")))
    if not _succeeded(result):
        raise WorkerError("UPSTREAM", "Not added (is it already in that playlist?)")
    added = result.get("playlistEditResults") if isinstance(result, dict) else None
    return {"added": [{"videoId": a.get("videoId"), "setVideoId": a.get("setVideoId")} for a in added or []]}


def m_remove_from_playlist(worker, params):
    worker.require_auth()
    playlist_id = req_str(params, "playlistId")
    items = req_list(params, "items")
    videos = []
    for item in items:
        if not isinstance(item, dict) or not item.get("videoId") or not item.get("setVideoId"):
            raise WorkerError("BAD_REQUEST", "each item needs videoId and setVideoId")
        videos.append({"videoId": item["videoId"], "setVideoId": item["setVideoId"]})
    if not _succeeded(worker.yt.remove_playlist_items(playlist_id, videos)):
        raise WorkerError("UPSTREAM", "YouTube Music did not remove the songs")
    return {"ok": True}


def m_delete_playlist(worker, params):
    worker.require_auth()
    result = worker.yt.delete_playlist(req_str(params, "playlistId"))
    # ytmusicapi returns the status string when YouTube sends one and the whole
    # response otherwise; a successful delete comes back without any status.
    failed = (isinstance(result, str) and result != "STATUS_SUCCEEDED") or (isinstance(result, dict) and "error" in result)
    if failed:
        raise WorkerError("UPSTREAM", "YouTube Music did not delete the playlist")
    return {"ok": True}


METHODS = {
    "ping": m_ping,
    "hello": m_hello,
    "reloadAuth": m_reload_auth,
    "verifyAuth": m_verify_auth,
    "search": m_search,
    "suggestions": m_suggestions,
    "home": m_home,
    "history": m_history,
    "libraryPlaylists": m_library_playlists,
    "playlist": m_playlist,
    "liked": m_liked,
    "album": m_album,
    "artist": m_artist,
    "song": m_song,
    "upNext": m_up_next,
    "resolve": m_resolve,
    "warmStreams": m_warm_streams,
    "cacheThumbs": m_cache_thumbs,
    "likeStatus": m_like_status,
    "rate": m_rate,
    "createPlaylist": m_create_playlist,
    "addToPlaylist": m_add_to_playlist,
    "removeFromPlaylist": m_remove_from_playlist,
    "deletePlaylist": m_delete_playlist,
}


class Worker:
    def __init__(self, client=None, auth_state="none", resolver=None, cache=None, thumbs=None):
        self.verified = False
        self._lock = threading.Lock()
        self._resolver = resolver
        self._warm_thread = None
        self._cache = cache
        self._thumbs = thumbs
        # Set by serve(): writes an unsolicited event line (thread-safe).
        self.emit = None
        if client is None:
            self.load()
        else:
            self.yt, self.auth = client, auth_state

    def resolver(self):
        # Asked for from the streams lane and the main thread (warm-up).
        with self._lock:
            if self._resolver is None:
                self._resolver = streams.Resolver()
            return self._resolver

    def warm_resolver(self):
        """Load yt-dlp in the background (~0.3 s) while the user browses."""
        warm = getattr(self.resolver(), "warm", None)
        if warm is None or (self._warm_thread and self._warm_thread.is_alive()):
            return
        self._warm_thread = threading.Thread(target=warm, daemon=True)
        self._warm_thread.start()

    def wait_for_warm(self):
        if self._warm_thread:
            self._warm_thread.join()

    def cache(self):
        if self._cache is None:
            self._cache = caches.DiskCache()
        return self._cache

    def thumbs(self):
        if self._thumbs is None:
            self._thumbs = caches.ThumbCache()
        return self._thumbs

    def clear_cache(self):
        try:
            self.cache().clear()
        except OSError as exc:
            norm.log(f"could not clear the cache: {exc}")

    def _after_success(self, name, params, mode, result):
        # A cache that can't be written must never fail the request itself.
        try:
            if name in CACHEABLE and mode in ("prefer", "refresh"):
                self.cache().put(name, params, result)
            for method, key in INVALIDATES.get(name, []):
                self.cache().invalidate(method, {key: params.get(key)} if key else None)
        except OSError as exc:
            norm.log(f"cache update failed: {exc}")

    def load(self):
        self.yt, self.auth = auth.load_client()
        self.verified = False

    def verify_session(self):
        """Check once per worker that YouTube still accepts the saved session.

        An expired session doesn't fail cleanly: the library comes back empty
        and other calls fail to parse. The account lookup fails fast (~0.1 s).
        """
        if self.auth != "ok" or self.verified:
            return
        try:
            self.yt.get_account_info()
        except Exception as exc:  # noqa: BLE001
            error = classify(exc)
            if error.retryable:
                raise error from exc  # offline or rate limited: can't tell, don't mark expired
            self.auth = "expired"
            return
        self.verified = True

    def require_auth(self):
        self.verify_session()
        if self.auth == "expired":
            raise WorkerError("AUTH_EXPIRED", "YouTube Music no longer accepts the saved session; sign in again")
        if self.auth != "ok":
            raise WorkerError("AUTH_REQUIRED", "Sign in to use your library")

    def handle(self, request):
        request_id = request.get("id") if isinstance(request, dict) else None
        started = time.monotonic()
        try:
            if not isinstance(request, dict):
                raise WorkerError("BAD_REQUEST", "request must be a JSON object")
            method = METHODS.get(request.get("method"))
            if method is None:
                raise WorkerError("BAD_REQUEST", f"unknown method {request.get('method')!r}")
            params = request.get("params") or {}
            if not isinstance(params, dict):
                raise WorkerError("BAD_REQUEST", "'params' must be an object")
            name = request.get("method")
            mode = "bypass"
            if name in CACHEABLE:
                params = dict(params)
                mode = params.pop("cache", "bypass")
                if mode not in CACHE_MODES:
                    raise WorkerError("BAD_REQUEST", f"'cache' must be one of {', '.join(CACHE_MODES)}")
                hit = self.cache().get(name, params) if mode == "prefer" else None
                if hit is not None:
                    return {"id": request_id, "ok": True, "result": hit[0], "cached": True, "age": hit[1],
                            "ms": round((time.monotonic() - started) * 1000)}
            result = method(self, params)
            self._after_success(name, params, mode, result)
            reply = {"id": request_id, "ok": True, "result": result}
            if name in CACHEABLE:
                reply["cached"] = False
        except Exception as exc:  # noqa: BLE001 - every failure becomes a protocol error
            error = classify(exc)
            if error.code == "AUTH_EXPIRED":
                self.auth = "expired"
            if error.code in ("INTERNAL", "UPSTREAM"):
                norm.log(f"{request.get('method') if isinstance(request, dict) else '?'} failed: "
                         + "".join(traceback.format_exception_only(type(exc), exc)).strip())
            reply = {"id": request_id, "ok": False, "error": error.as_dict()}
        reply["ms"] = round((time.monotonic() - started) * 1000)
        return reply


def ytmusicapi_version():
    from importlib.metadata import PackageNotFoundError, version

    try:
        return version("ytmusicapi")
    except PackageNotFoundError:
        return None


# ---- serve ------------------------------------------------------------------


def serve(idle_secs, worker=None, stdin_fd=None, out=None):
    """Answer JSON-lines requests until stdin closes or the idle timeout hits."""
    if out is None:
        out = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
        # Anything else that prints must never corrupt the protocol stream.
        sys.stdout = sys.stderr
    lock = threading.Lock()

    def emit(message):
        # Background downloads report through here too, hence the lock.
        with lock:
            out.write(json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n")
            out.flush()

    worker = worker or Worker()
    worker.emit = emit
    lanes = {}

    def submit(request):
        name = LANES[request["method"]]
        jobs = lanes.get(name)
        if jobs is None:
            jobs = lanes[name] = queue.Queue()

            def run():
                while True:
                    emit(worker.handle(jobs.get()))

            # Daemon: an unfinished lookup must not keep the process alive
            # after stdin closes.
            threading.Thread(target=run, name=f"lane-{name}", daemon=True).start()
        jobs.put(request)

    emit({"event": "ready", "protocol": PROTOCOL, "version": VERSION,
          "ytmusicapi": ytmusicapi_version(), "auth": worker.auth})
    fd = sys.stdin.fileno() if stdin_fd is None else stdin_fd
    buffer = b""
    while True:
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                request = json.loads(line)
            except ValueError:
                emit({"id": None, "ok": False, "ms": 0,
                      "error": WorkerError("BAD_REQUEST", "request is not valid JSON").as_dict()})
                continue
            if isinstance(request, dict) and request.get("method") == "shutdown":
                emit({"id": request.get("id"), "ok": True, "result": {}, "ms": 0})
                return 0
            if isinstance(request, dict) and request.get("method") in LANES:
                submit(request)
                continue
            emit(worker.handle(request))
        ready, _, _ = select.select([fd], [], [], idle_secs if idle_secs > 0 else None)
        if not ready:
            emit({"event": "idle-exit"})
            return 0
        chunk = os.read(fd, 65536)
        if not chunk:
            return 0  # stdin closed: the shell side is gone
        buffer += chunk


# ---- CLI --------------------------------------------------------------------


def print_json(value):
    print(json.dumps(value, indent=2, ensure_ascii=False))


def notify_shell():
    """Tell a running shell to re-read the session; harmless if none is running."""
    try:
        subprocess.run(["omarchy-shell", "-q", "ytmusic", "reloadAuth"], timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except (OSError, subprocess.SubprocessError):
        pass


def cmd_auth(args):
    try:
        if args.paste:
            print("Paste the request headers of a music.youtube.com /browse request, then press Ctrl-D:",
                  file=sys.stderr)
            account = auth.import_from_headers(sys.stdin.read())
        elif args.clipboard:
            raw = subprocess.run(["wl-paste", "--no-newline"], capture_output=True, text=True, check=False).stdout
            subprocess.run(["wl-copy", "--clear"], check=False)
            print("Clipboard cleared. Omarchy's clipboard history still holds a copy: delete it there.",
                  file=sys.stderr)
            account = auth.import_from_headers(raw)
        else:
            browser, _, profile = (args.from_browser or "chromium").partition(":")
            account = auth.import_from_browser(browser, profile or None, args.authuser, args.keyring)
    except auth.AuthError as exc:
        print(f"Sign-in failed: {exc}", file=sys.stderr)
        return 1
    name = account.get("name") or "your account"
    handle = f" ({account['handle']})" if account.get("handle") else ""
    caches.DiskCache().clear()  # cached library data belongs to the previous session
    print(f"Signed in to YouTube Music as {name}{handle}.")
    notify_shell()
    return 0


def cmd_selftest(args):
    checks = []

    def check(label, fn):
        try:
            detail = fn()
            checks.append((True, label, detail or ""))
        except Exception as exc:  # noqa: BLE001
            checks.append((False, label, f"{type(exc).__name__}: {exc}"))

    check("ytmusicapi import", lambda: f"ytmusicapi {ytmusicapi_version()}")
    check("normalizer", lambda: norm.track({"videoId": "x", "title": "t", "length": "1:05",
                                          "artists": [{"name": "a", "id": None}]})["durationSec"] == 65 or 1 / 0)

    class Offline:
        pass

    check("dispatcher", lambda: Worker(Offline(), "none").handle({"id": 1, "method": "ping"})["ok"] or 1 / 0)

    def permissions():
        directory = auth.config_dir()
        if not directory.exists():
            return "no session saved"
        bad = [p.name for p in directory.iterdir() if p.is_file() and p.stat().st_mode & 0o077]
        if directory.stat().st_mode & 0o077 or bad:
            raise PermissionError(f"too open: {directory} {bad}")
        return "0700/0600"

    check("session file permissions", permissions)

    def tools():
        import shutil

        missing = [tool for tool in ("mpv", "yt-dlp", "deno") if shutil.which(tool) is None]
        if not any(os.path.exists(p) for p in ("/etc/mpv/scripts/mpris.so", "/usr/lib/mpv-mpris/mpris.so")):
            missing.append("mpv-mpris")
        if missing:
            raise RuntimeError(f"missing {', '.join(missing)}; install with: omarchy-pkg-add {' '.join(missing)}")
        return "mpv, mpv-mpris, yt-dlp, deno"

    check("tools", tools)
    if args.online:
        worker = Worker()
        check("online search", lambda: f"{len(worker.handle({'method': 'search', 'params': {'query': 'daft punk', 'filter': 'songs', 'limit': 1}})['result']['items'])} result(s)")
        if worker.auth == "ok":
            def library():
                reply = worker.handle({"method": "libraryPlaylists", "params": {"limit": 1}})
                if not reply["ok"]:
                    raise RuntimeError(reply["error"]["code"])
                return "signed in"

            check("library (signed in)", library)
    for ok, label, detail in checks:
        print(f"{'PASS' if ok else 'FAIL'}  {label}{': ' + str(detail) if detail not in ('', True) else ''}")
    return 0 if all(ok for ok, _, _ in checks) else 1


RECORDERS = {
    "search": lambda yt, p: yt.search(p["query"], filter=p.get("filter"), limit=p.get("limit", 20)),
    "album": lambda yt, p: yt.get_album(p["browseId"]),
    "artist": lambda yt, p: yt.get_artist(p["channelId"]),
    "song": lambda yt, p: yt.get_song(p["videoId"]),
    "watch": lambda yt, p: yt.get_watch_playlist(videoId=p["videoId"], limit=p.get("limit", 25), radio=p.get("radio", False)),
    "home": lambda yt, p: yt.get_home(limit=p.get("limit", 3)),
    "history": lambda yt, p: yt.get_history(),
    "libraryPlaylists": lambda yt, p: yt.get_library_playlists(limit=p.get("limit", 25)),
    "playlist": lambda yt, p: yt.get_playlist(p["playlistId"], limit=p.get("limit", 100)),
    "liked": lambda yt, p: yt.get_liked_songs(limit=p.get("limit", 100)),
}
SCRUB_KEYS = ("streamingData", "playbackTracking", "playerConfig", "microformat", "responseContext", "trackingParams")


def scrub(value):
    """Drop tokens and stream URLs before a response becomes a test fixture."""
    if isinstance(value, dict):
        return {k: scrub(v) for k, v in value.items() if k not in SCRUB_KEYS and "Token" not in k and "token" not in k}
    if isinstance(value, list):
        return [scrub(v) for v in value]
    return value


def cmd_record(args):
    worker = Worker()
    data = RECORDERS[args.method](worker.yt, json.loads(args.params))
    with open(args.out, "w") as f:
        json.dump(scrub(data), f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {args.out}", file=sys.stderr)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="ytm", description="YouTube Music backend for damir.ytmusic")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("serve", help="JSON-lines worker for the shell")
    p.add_argument("--idle", type=float, default=180, help="exit after this many idle seconds (0 = never)")
    p = sub.add_parser("search", help="search YouTube Music")
    p.add_argument("query", nargs="+")
    p.add_argument("--filter", choices=SEARCH_FILTERS)
    p.add_argument("--limit", type=int, default=20)
    p = sub.add_parser("call", help="call any worker method")
    p.add_argument("method", choices=sorted(METHODS))
    p.add_argument("params", nargs="?", default="{}", help="JSON object")
    p = sub.add_parser("auth", help="sign in (default: import from a Chromium profile)")
    source = p.add_mutually_exclusive_group()
    source.add_argument("--from-browser", metavar="BROWSER[:PROFILE]", help="default chromium, auto-detected profile")
    source.add_argument("--paste", action="store_true", help="read request headers from stdin")
    source.add_argument("--clipboard", action="store_true", help="read request headers from the clipboard")
    p.add_argument("--authuser", type=int, default=0, help="Google account index when signed in to several")
    p.add_argument("--keyring", default="GNOMEKEYRING", help="keyring holding the browser's cookie key")
    sub.add_parser("logout", help="delete the saved session")
    sub.add_parser("whoami", help="show the signed-in account")
    p = sub.add_parser("selftest", help="check the installation")
    p.add_argument("--online", action="store_true", help="also make read-only network calls")
    p = sub.add_parser("record", help="save a raw, scrubbed ytmusicapi response (test fixtures)")
    p.add_argument("method", choices=sorted(RECORDERS))
    p.add_argument("params", help="JSON object")
    p.add_argument("out")
    args = parser.parse_args(argv)

    if args.cmd == "serve":
        return serve(args.idle)
    if args.cmd in ("search", "call"):
        if args.cmd == "search":
            request = {"id": 1, "method": "search",
                       "params": {"query": " ".join(args.query), "filter": args.filter, "limit": args.limit}}
        else:
            try:
                params = json.loads(args.params)
            except ValueError:
                parser.error("params must be a JSON object")
            request = {"id": 1, "method": args.method, "params": params}
        reply = Worker().handle(request)
        print_json(reply["result"] if reply["ok"] else {"error": reply["error"]})
        return 0 if reply["ok"] else 1
    if args.cmd == "auth":
        return cmd_auth(args)
    if args.cmd == "logout":
        removed = auth.logout()
        caches.DiskCache().clear()
        print(f"Signed out ({', '.join(removed) if removed else 'no session was saved'}).")
        notify_shell()
        return 0
    if args.cmd == "whoami":
        print_json(auth.whoami() or {"signedIn": False})
        return 0
    if args.cmd == "selftest":
        return cmd_selftest(args)
    if args.cmd == "record":
        return cmd_record(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
