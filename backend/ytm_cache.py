"""On-disk caches for the worker, outside the plugin directory.

- DiskCache: recent library / playlist / album / artist / home / history
  responses, so the panel can show them instantly and refresh them in the
  background (stale-while-revalidate). Cleared whenever the account changes.
- ThumbCache: cover thumbnails as files, so covers appear instantly without
  the shell keeping decoded images in memory.

Both live in ~/.cache/omarchy-ytmusic (override: YTM_CACHE_DIR), 0700 / 0600.
"""

import hashlib
import json
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse

THUMB_HOSTS = ("googleusercontent.com", "ggpht.com", "ytimg.com")


def cache_root():
    return Path(os.environ.get("YTM_CACHE_DIR") or Path.home() / ".cache/omarchy-ytmusic")


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def write_private(path, data):
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


class DiskCache:
    MAX_AGE = 7 * 24 * 3600
    MAX_FILES = 150

    def __init__(self, root=None):
        self.dir = Path(root) if root else cache_root() / "data"

    def _ensure_dir(self):
        # The parent (~/.cache/omarchy-ytmusic) also holds session.json, so it
        # must be private too, not just this subdirectory.
        private_dir(self.dir.parent)
        private_dir(self.dir)

    @staticmethod
    def key(method, params):
        canonical = json.dumps(params or {}, sort_keys=True, separators=(",", ":"))
        return f"{method}-{hashlib.sha1(canonical.encode()).hexdigest()[:20]}.json"

    def get(self, method, params, now=None):
        """``(result, age_seconds)`` or ``None``."""
        try:
            entry = json.loads((self.dir / self.key(method, params)).read_text())
        except (OSError, ValueError):
            return None
        age = (now if now is not None else time.time()) - entry.get("at", 0)
        if age < 0 or age > self.MAX_AGE or "result" not in entry:
            return None
        return entry["result"], int(age)

    def put(self, method, params, result, now=None):
        self._ensure_dir()
        entry = {"method": method, "params": params or {}, "at": now if now is not None else time.time(), "result": result}
        write_private(self.dir / self.key(method, params),
                      json.dumps(entry, ensure_ascii=False, separators=(",", ":")).encode())
        self._prune()

    def invalidate(self, method, match=None):
        for path in self.dir.glob(f"{method}-*.json"):
            if match:
                try:
                    params = json.loads(path.read_text()).get("params", {})
                except (OSError, ValueError):
                    params = {}
                if any(params.get(k) != v for k, v in match.items()):
                    continue
            path.unlink(missing_ok=True)

    def clear(self):
        for path in self.dir.glob("*.json"):
            path.unlink(missing_ok=True)

    def _prune(self):
        files = sorted(self.dir.glob("*.json"), key=lambda p: p.stat().st_mtime)
        for path in files[:-self.MAX_FILES]:
            path.unlink(missing_ok=True)


def _http_get(url):
    import requests

    response = requests.get(url, timeout=6)
    if response.status_code != 200 or not response.headers.get("content-type", "").startswith("image/"):
        return None
    if len(response.content) > 2_000_000:
        return None
    return response.content


class ThumbCache:
    MAX_BYTES = 40 * 1024 * 1024

    def __init__(self, root=None, downloader=None, workers=6):
        self.dir = Path(root) if root else cache_root() / "thumbs"
        self._download = downloader or _http_get
        self._workers = workers
        self._lock = threading.Lock()

    @staticmethod
    def allowed(url):
        try:
            parsed = urlparse(url)
        except (TypeError, ValueError):
            return False
        host = parsed.hostname or ""
        return parsed.scheme == "https" and any(host == h or host.endswith("." + h) for h in THUMB_HOSTS)

    def path_for(self, url):
        return self.dir / (hashlib.sha1(url.encode()).hexdigest() + ".img")

    def cached(self, urls):
        """``{url: path}`` for the ones already on disk."""
        found = {}
        for url in urls:
            if self.allowed(url):
                path = self.path_for(url)
                if path.exists():
                    found[url] = str(path)
        return found

    def fetch(self, urls):
        """Download the missing ones; ``{url: path}`` for everything now on disk."""
        wanted = [u for u in dict.fromkeys(urls) if self.allowed(u)]
        have = self.cached(wanted)
        missing = [u for u in wanted if u not in have]
        if missing:
            private_dir(self.dir.parent)
            private_dir(self.dir)
            with ThreadPoolExecutor(max_workers=self._workers) as pool:
                for url, data in zip(missing, pool.map(self._safe_download, missing)):
                    if data:
                        path = self.path_for(url)
                        write_private(path, data)
                        have[url] = str(path)
            self._prune()
        return have

    def _safe_download(self, url):
        try:
            return self._download(url)
        except Exception:  # noqa: BLE001 - a missing cover is not an error
            return None

    def _prune(self):
        with self._lock:
            files = sorted(self.dir.glob("*.img"), key=lambda p: p.stat().st_mtime)
            total = sum(p.stat().st_size for p in files)
            for path in files:
                if total <= self.MAX_BYTES:
                    break
                total -= path.stat().st_size
                path.unlink(missing_ok=True)
