import ytm_normalize as norm

TRACK_KEYS = {"type", "videoId", "title", "artists", "artistText", "album", "durationSec", "thumb",
              "thumbLarge", "explicit", "likeStatus", "setVideoId", "available", "kind", "played"}


def test_parse_duration():
    assert norm.parse_duration("5:54") == 354
    assert norm.parse_duration("1:02:03") == 3723
    assert norm.parse_duration(200) == 200
    assert norm.parse_duration(None) is None
    assert norm.parse_duration("live") is None


def test_to_int():
    assert norm.to_int("1,234 songs") == 1234
    assert norm.to_int(25) == 25
    assert norm.to_int("no songs") is None
    assert norm.to_int(None) is None


def test_resize_googleusercontent_sizes():
    url = "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj"
    assert norm.resize(url, 120) == "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj"
    avatar = "https://yt3.ggpht.com/xyz=s88-c-k-c0x00ffffff-no-rj"
    assert norm.resize(avatar, 544) == "https://yt3.ggpht.com/xyz=s544"
    video = "https://i.ytimg.com/vi/abc/hqdefault.jpg"
    assert norm.resize(video, 120) == video


def test_thumbs_picks_small_and_large():
    small, large = norm.thumbs([
        {"url": "https://lh3.googleusercontent.com/a=w226-h226-l90-rj", "width": 226},
        {"url": "https://lh3.googleusercontent.com/a=w60-h60-l90-rj", "width": 60},
    ])
    assert small.endswith("=w120-h120-l90-rj")
    assert large.endswith("=w544-h544-l90-rj")
    assert norm.thumbs(None) == (None, None)


def test_track_has_every_field():
    track = norm.track({"videoId": "v", "title": "T", "length": "3:05", "artists": [{"name": "A", "id": "UC1"}]})
    assert set(track) == TRACK_KEYS
    assert track["durationSec"] == 185
    assert track["artistText"] == "A"
    assert track["album"] is None
    assert track["available"] is True
    assert track["kind"] == "song"


def test_malformed_items_are_skipped():
    items = norm.normalize_list([{"title": "no id"}, {"videoId": "ok"}], norm.track)
    assert [t["videoId"] for t in items] == ["ok"]


def test_search_songs_fixture(load_fixture):
    tracks = norm.normalize_list(load_fixture("search_songs.json"), norm.search_item)
    assert tracks
    for track in tracks:
        assert set(track) == TRACK_KEYS
        assert track["kind"] == "song"
        assert track["artists"] and track["artistText"]
        assert isinstance(track["durationSec"], int)
        assert track["thumb"].startswith("https://")
        assert track["album"] and track["album"]["name"]


def test_search_mixed_fixture_is_grouped(load_fixture):
    groups = norm.search_grouped(load_fixture("search_mixed.json"))
    assert set(groups) == {"top", "songs", "videos", "albums", "playlists", "artists"}
    assert groups["top"], "a mixed search has a top result"
    expected = {"songs": "track", "videos": "track", "albums": "album", "playlists": "playlist", "artists": "artist"}
    for key, kind in expected.items():
        assert all(item["type"] == kind for item in groups[key]), key
    assert all(item["kind"] == "video" for item in groups["videos"])
    assert groups["songs"] and groups["albums"] and groups["artists"]
    # The top-result artist card's songs arrive without artists (ytmusicapi).
    assert all(song["artistText"] for song in groups["songs"])
    giorgio = next(song for song in groups["songs"] if song["title"] == "Giorgio by Moroder")
    assert giorgio["artistText"] == "Daft Punk"


def test_songs_keep_their_own_artists_without_an_artist_top_result():
    groups = norm.search_grouped([
        {"category": "Top result", "resultType": "song", "videoId": "t", "title": "T", "artists": [{"name": "X"}]},
        {"resultType": "song", "videoId": "a", "title": "A"},
    ])
    assert groups["songs"][0]["artists"] == []


def test_top_result_artist_uses_artists_entry():
    item = norm.search_item({"category": "Top result", "resultType": "artist", "subscribers": "79.4M",
                             "artists": [{"name": "Daft Punk", "id": "UCdaft"}]})
    assert (item["type"], item["name"], item["channelId"], item["subtitle"]) == ("artist", "Daft Punk", "UCdaft", "79.4M")


def test_album_fixture_fills_track_album_and_thumbs(load_fixture):
    data = load_fixture("album.json")
    col = norm.collection("album", data, "MPREb_test")
    assert col["kind"] == "album" and not col["editable"]
    assert col["tracks"] and col["trackCount"] >= len(col["tracks"])
    assert col["playlistId"] and col["playlistId"].startswith("OLAK")
    for track in col["tracks"]:
        assert track["album"] == {"name": col["title"], "id": "MPREb_test"}
        assert track["thumb"] == col["thumb"]
        assert isinstance(track["durationSec"], int)
        # The recorded album tags every track MUSIC_VIDEO_TYPE_OMV; they're still songs.
        assert track["kind"] == "song"


def test_watch_playlist_tracks_use_length_and_thumbnail(load_fixture):
    tracks = norm.normalize_list(load_fixture("watch.json")["tracks"], norm.track)
    assert tracks
    assert all(isinstance(t["durationSec"], int) and t["thumb"] for t in tracks)


def test_artist_page_fixture(load_fixture):
    page = norm.artist_page("UCtest", load_fixture("artist.json"))
    assert page["name"]
    assert page["songs"] and all(s["type"] == "track" for s in page["songs"])
    assert page["albums"] and all(a["type"] == "album" and a["artists"] for a in page["albums"])


def test_song_fixture(load_fixture):
    track = norm.song(load_fixture("song.json"))
    assert set(track) == TRACK_KEYS
    assert track["videoId"] and track["title"] and track["artistText"]
    assert isinstance(track["durationSec"], int)
    assert track["thumbLarge"]


def test_playlist_collection_keeps_set_video_ids():
    data = {
        "id": "PLx", "title": "Mine", "owned": True, "trackCount": 3,
        "author": {"name": "Me", "id": "UCme"},
        "thumbnails": [{"url": "https://i.ytimg.com/x.jpg", "width": 400}],
        "tracks": [
            {"videoId": "a", "title": "A", "setVideoId": "S1", "duration_seconds": 100, "artists": [{"name": "X"}]},
            {"videoId": "b", "title": "B", "setVideoId": "S2", "duration": "2:00", "isAvailable": False},
        ],
    }
    col = norm.collection("playlist", data, "PLx")
    assert col["editable"] and col["owned"] and col["truncated"]
    assert col["subtitle"] == "Me • 3 songs"
    assert [t["setVideoId"] for t in col["tracks"]] == ["S1", "S2"]
    assert col["tracks"][1]["available"] is False


def test_liked_collection_is_not_editable():
    col = norm.collection("liked", {"owned": True, "trackCount": 1, "tracks": [{"videoId": "a", "likeStatus": "LIKE"}]}, "LM")
    assert col["title"] == "Liked Music" and col["playlistId"] == "LM"
    assert not col["editable"]
    assert col["tracks"][0]["likeStatus"] == "LIKE"


def test_library_playlist_and_history_shapes():
    playlist = norm.playlist({"playlistId": "PLx", "title": "Mine", "owned": True, "count": "12 songs",
                              "thumbnails": []})
    assert playlist["count"] == 12 and playlist["owned"]
    assert norm.playlist({"browseId": "VLPLy", "title": "Theirs", "author": [{"name": "Bob"}]})["playlistId"] == "PLy"
    item = norm.track({"videoId": "h", "title": "H", "played": "Today", "duration": "1:00"})
    assert item["played"] == "Today"


def test_home_items_dispatch_by_shape():
    shelves = norm.home([{"title": "Mixed", "contents": [
        {"videoId": "v", "title": "Song", "playlistId": "RDx", "artists": []},
        {"browseId": "MPREb_1", "title": "Album", "audioPlaylistId": "OLAK1"},
        {"playlistId": "PL1", "title": "List", "count": "5"},
        {"browseId": "UC1", "title": "Artist", "subscribers": "1M"},
        {"title": "unknown"},
    ]}, {"title": "Empty", "contents": []}])
    assert [shelf["title"] for shelf in shelves] == ["Mixed"]
    assert [item["type"] for item in shelves[0]["items"]] == ["track", "album", "playlist", "artist"]


def test_account():
    assert norm.account({"accountName": "N", "channelHandle": "@n", "accountPhotoUrl": "u"}) == \
        {"name": "N", "handle": "@n", "photo": "u"}
