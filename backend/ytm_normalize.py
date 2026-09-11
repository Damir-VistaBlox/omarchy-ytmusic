"""Turn ytmusicapi responses into the plugin's stable JSON shapes.

ytmusicapi's shapes differ per endpoint (``thumbnails`` vs ``thumbnail``,
``duration_seconds`` vs ``"5:54"`` strings, album tracks without thumbnails,
``artist`` vs ``title``), so the QML side only ever sees these shapes. Every
normalizer returns all documented fields, using ``None`` when a value is
unknown. A single malformed item is skipped and logged rather than failing a
whole response.
"""

import re
import sys

THUMB_SIZE = 120
LARGE_SIZE = 544

LIKE_STATUSES = ("LIKE", "DISLIKE", "INDIFFERENT")
VIDEO_TYPES = (
    "MUSIC_VIDEO_TYPE_OMV",
    "MUSIC_VIDEO_TYPE_UGC",
    "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC",
)

# Size suffixes on googleusercontent / ggpht image URLs, e.g. "=w60-h60-l90-rj"
# or "=s88-c-k-c0x00ffffff-no-rj". Rewriting them fetches a fitting size.
_SIZE_WH = re.compile(r"=w\d+-h\d+[^/=]*$")
_SIZE_S = re.compile(r"=s\d+[^/=]*$")


def log(message):
    print(f"ytm: {message}", file=sys.stderr)


def resize(url, size):
    if not url:
        return None
    if "googleusercontent.com" in url or "ggpht.com" in url:
        if _SIZE_WH.search(url):
            return _SIZE_WH.sub(f"=w{size}-h{size}-l90-rj", url)
        if _SIZE_S.search(url):
            return _SIZE_S.sub(f"=s{size}", url)
    return url


def thumbs(thumbnails):
    """Return ``(thumb, thumbLarge)`` URLs from a ytmusicapi thumbnail list."""
    items = [t for t in (thumbnails or []) if isinstance(t, dict) and t.get("url")]
    if not items:
        return None, None
    items.sort(key=lambda t: t.get("width") or 0)
    small = next((t for t in items if (t.get("width") or 0) >= THUMB_SIZE), items[-1])
    return resize(small["url"], THUMB_SIZE), resize(items[-1]["url"], LARGE_SIZE)


def parse_duration(value):
    """Seconds from ``"5:54"``, ``"1:02:03"`` or a number; ``None`` if unknown."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    parts = str(value).strip().split(":")
    try:
        numbers = [int(part) for part in parts]
    except ValueError:
        return None
    total = 0
    for number in numbers:
        total = total * 60 + number
    return total


def to_int(value):
    """``25``, ``"25"``, ``"1,234 songs"`` -> int; ``None`` otherwise."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    match = re.search(r"\d[\d,.]*", str(value))
    if not match:
        return None
    try:
        return int(match.group(0).replace(",", "").replace(".", ""))
    except ValueError:
        return None


def artists(value):
    out = []
    for artist in value or []:
        if isinstance(artist, dict) and artist.get("name"):
            out.append({"name": artist["name"], "id": artist.get("id")})
        elif isinstance(artist, str) and artist:
            out.append({"name": artist, "id": None})
    return out


def artist_text(artist_list):
    return ", ".join(artist["name"] for artist in artist_list)


def like_status(value):
    return value if value in LIKE_STATUSES else None


def track_kind(item):
    if item.get("resultType") == "video" or item.get("videoType") in VIDEO_TYPES:
        return "video"
    return "song"


def _album_ref(value):
    if isinstance(value, dict) and value.get("name"):
        return {"name": value["name"], "id": value.get("id")}
    if isinstance(value, str) and value:
        return {"name": value, "id": None}
    return None


def track(item, album=None, album_thumbs=None):
    """A playable song or video. ``album``/``album_thumbs`` fill gaps in album tracks."""
    video_id = item.get("videoId")
    if not video_id:
        raise ValueError("track without videoId")
    artist_list = artists(item.get("artists"))
    album_value = _album_ref(item.get("album"))
    if album and (album_value is None or album_value["id"] is None):
        album_value = album
    thumb, thumb_large = thumbs(item.get("thumbnails") or item.get("thumbnail"))
    if thumb is None and album_thumbs:
        thumb, thumb_large = album_thumbs
    duration = item.get("duration_seconds")
    if duration is None:
        duration = parse_duration(item.get("duration") or item.get("length"))
    return {
        "type": "track",
        "videoId": video_id,
        "title": item.get("title") or "",
        "artists": artist_list,
        "artistText": artist_text(artist_list),
        "album": album_value,
        "durationSec": duration,
        "thumb": thumb,
        "thumbLarge": thumb_large,
        "explicit": bool(item.get("isExplicit")),
        "likeStatus": like_status(item.get("likeStatus")),
        "setVideoId": item.get("setVideoId"),
        "available": item.get("isAvailable", True) is not False,
        "kind": track_kind(item),
        "played": item.get("played"),
    }


def album_track(item, album_ref, album_thumbs):
    """A track on an album page. These are the album's songs even when YouTube
    tags them MUSIC_VIDEO_TYPE_OMV (it does for whole albums that have videos)."""
    value = track(item, album=album_ref, album_thumbs=album_thumbs)
    value["kind"] = "song"
    return value


def album(item, fallback_artists=None):
    browse_id = item.get("browseId")
    if not browse_id:
        raise ValueError("album without browseId")
    artist_list = artists(item.get("artists")) or list(fallback_artists or [])
    thumb, thumb_large = thumbs(item.get("thumbnails"))
    return {
        "type": "album",
        "browseId": browse_id,
        "playlistId": item.get("playlistId") or item.get("audioPlaylistId"),
        "title": item.get("title") or "",
        "artists": artist_list,
        "artistText": artist_text(artist_list),
        "year": str(item["year"]) if item.get("year") else None,
        "albumType": item.get("type"),
        "thumb": thumb,
        "thumbLarge": thumb_large,
    }


def _author_name(value):
    if isinstance(value, list):
        return artist_text(artists(value)) or None
    if isinstance(value, dict):
        return value.get("name")
    return value or None


def playlist(item):
    playlist_id = item.get("playlistId") or item.get("browseId")
    if not playlist_id:
        raise ValueError("playlist without id")
    if playlist_id.startswith("VL"):
        playlist_id = playlist_id[2:]
    thumb, thumb_large = thumbs(item.get("thumbnails"))
    return {
        "type": "playlist",
        "playlistId": playlist_id,
        "title": item.get("title") or "",
        "author": _author_name(item.get("author")),
        "count": to_int(item.get("count") if item.get("count") is not None else item.get("itemCount")),
        "owned": bool(item.get("owned")),
        "thumb": thumb,
        "thumbLarge": thumb_large,
    }


def artist(item):
    # A "Top result" artist carries its name and id only in artists[0].
    listed = artists(item.get("artists"))
    first = listed[0] if listed else {"name": None, "id": None}
    channel_id = item.get("browseId") or item.get("channelId") or first["id"]
    if not channel_id:
        raise ValueError("artist without channel id")
    thumb, thumb_large = thumbs(item.get("thumbnails"))
    return {
        "type": "artist",
        "channelId": channel_id,
        "name": item.get("artist") or item.get("title") or item.get("name") or first["name"] or "",
        "subtitle": item.get("subscribers") or item.get("monthlyListeners"),
        "thumb": thumb,
        "thumbLarge": thumb_large,
    }


def search_item(item):
    kind = item.get("resultType")
    if kind in ("song", "video"):
        return track(item)
    if kind == "album":
        return album(item)
    if kind == "playlist":
        return playlist(item)
    if kind == "artist":
        return artist(item)
    return None  # podcasts, episodes, profiles: not supported


def home_item(item):
    browse_id = str(item.get("browseId") or "")
    if item.get("videoId"):
        return track(item)
    if browse_id.startswith("MPRE"):
        return album(item)
    if browse_id.startswith("UC"):
        return artist(item)
    if item.get("playlistId"):
        return playlist(item)
    return None


def normalize_list(items, fn, what="item"):
    out = []
    for item in items or []:
        try:
            value = fn(item)
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            log(f"skipped malformed {what}: {type(exc).__name__}: {exc}")
            continue
        if value is not None:
            out.append(value)
    return out


SEARCH_GROUPS = {"song": "songs", "video": "videos", "album": "albums", "playlist": "playlists", "artist": "artists"}


def search_grouped(results):
    """Unfiltered search: the top result plus one list per kind."""
    groups = {"top": [], "songs": [], "videos": [], "albums": [], "playlists": [], "artists": []}
    for raw in results or []:
        items = normalize_list([raw], search_item, "search result")
        if not items:
            continue
        if raw.get("category") == "Top result":
            groups["top"].append(items[0])
            continue
        key = SEARCH_GROUPS.get(raw.get("resultType"))
        if key:
            groups[key].append(items[0])
    # When the top result is an artist, YouTube Music's card lists a few of
    # their popular songs with only title and plays; ytmusicapi returns those
    # without artists. They belong to the top-result artist.
    top_artist = next((item for item in groups["top"] if item["type"] == "artist"), None)
    if top_artist and top_artist["name"]:
        credit = [{"name": top_artist["name"], "id": top_artist["channelId"]}]
        for song in groups["songs"]:
            if not song["artists"]:
                song["artists"] = list(credit)
                song["artistText"] = artist_text(credit)
    return groups


def home(shelves):
    out = []
    for shelf in shelves or []:
        items = normalize_list(shelf.get("contents"), home_item, "home item")
        if items:
            out.append({"title": shelf.get("title") or "", "items": items})
    return out


def _join(*parts):
    return " • ".join(str(part) for part in parts if part)


def collection(kind, data, collection_id=None):
    """An album, playlist or Liked Music with its tracks."""
    thumb, thumb_large = thumbs(data.get("thumbnails"))
    collection_id = collection_id or data.get("id")
    title = data.get("title") or ("Liked Music" if kind == "liked" else "")
    if kind == "album":
        ref = {"name": title, "id": collection_id}
        tracks = normalize_list(data.get("tracks"), lambda t: album_track(t, ref, (thumb, thumb_large)), "album track")
        album_artists = artists(data.get("artists"))
        subtitle = _join(data.get("type"), artist_text(album_artists), data.get("year"))
        playlist_id = data.get("audioPlaylistId")
    else:
        tracks = normalize_list(data.get("tracks"), track, f"{kind} track")
        count_text = f"{to_int(data.get('trackCount')) or len(tracks)} songs"
        subtitle = count_text if kind == "liked" else _join(_author_name(data.get("author")), count_text)
        playlist_id = "LM" if kind == "liked" else collection_id
    track_count = to_int(data.get("trackCount"))
    if track_count is None:
        track_count = len(tracks)
    owned = bool(data.get("owned"))
    return {
        "type": "collection",
        "kind": kind,
        "id": collection_id,
        "playlistId": playlist_id,
        "title": title,
        "subtitle": subtitle,
        "owned": owned,
        "editable": owned and kind == "playlist",
        "trackCount": track_count,
        "truncated": track_count > len(tracks),
        "thumb": thumb,
        "thumbLarge": thumb_large,
        "tracks": tracks,
    }


def artist_page(channel_id, data):
    name = data.get("name") or ""
    page_artists = [{"name": name, "id": channel_id}] if name else []
    thumb, thumb_large = thumbs(data.get("thumbnails"))
    songs = data.get("songs") or {}
    return {
        "type": "artistPage",
        "channelId": channel_id,
        "name": name,
        "subtitle": data.get("monthlyListeners") or data.get("subscribers"),
        "thumb": thumb,
        "thumbLarge": thumb_large,
        "songs": normalize_list(songs.get("results"), track, "artist song"),
        "albums": normalize_list((data.get("albums") or {}).get("results"), lambda a: album(a, page_artists), "artist album"),
        "singles": normalize_list((data.get("singles") or {}).get("results"), lambda a: album(a, page_artists), "artist single"),
        "songsPlaylistId": songs.get("browseId"),
    }


def song(data):
    """A track from ``get_song`` (player response ``videoDetails``)."""
    details = data.get("videoDetails") or {}
    item = {
        "videoId": details.get("videoId"),
        "title": details.get("title"),
        "artists": [{"name": details.get("author"), "id": details.get("channelId")}] if details.get("author") else [],
        "duration_seconds": to_int(details.get("lengthSeconds")),
        "thumbnails": (details.get("thumbnail") or {}).get("thumbnails"),
        "videoType": details.get("musicVideoType"),
    }
    return track(item)


def account(info):
    return {
        "name": info.get("accountName"),
        "handle": info.get("channelHandle"),
        "photo": info.get("accountPhotoUrl"),
    }
