// Pure helpers for damir.ytmusic, shared by the QML side and the Node tests
// (`node --test tests/`). Plain functions only — no `.pragma library` — so the
// same file loads in both.

var PLUGIN_ID = "damir.ytmusic"

// www.youtube.com is the only URL form mpv-mpris derives cover art from (S4).
var WATCH_URL = "https://www.youtube.com/watch?v="

function trackUrl(videoId) {
  return WATCH_URL + videoId
}

function videoIdFromUrl(url) {
  var text = String(url || "")
  var match = text.match(/[?&]v=([A-Za-z0-9_-]{11})/) || text.match(/youtu\.be\/([A-Za-z0-9_-]{11})/)
  return match ? match[1] : ""
}

function mediaTitle(track) {
  if (!track) return ""
  var title = String(track.title || "")
  var artists = String(track.artistText || "")
  return artists ? title + " — " + artists : title
}

function utf8Length(text) {
  var length = 0
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code < 0x80) length += 1
    else if (code < 0x800) length += 2
    else if (code >= 0xd800 && code <= 0xdbff) { length += 4; i++ }
    else length += 3
  }
  return length
}

// Per-file loadfile options. mpv's %n% form carries the value's byte length,
// so titles with commas, quotes or '=' need no escaping.
function loadfileOptions(track) {
  var title = mediaTitle(track)
  return title ? "force-media-title=%" + utf8Length(title) + "%" + title : ""
}

function loadfile(track, flag) {
  return ["loadfile", trackUrl(track.videoId), flag, -1, loadfileOptions(track)]
}

function playable(track) {
  return !!(track && track.videoId && track.available !== false)
}

// ---- queue commands ---------------------------------------------------------
// `state` is { count, pos } from mpv's playlist-count / playlist-pos.

function playNowCommands(track, state) {
  var count = state && state.count > 0 ? state.count : 0
  var pos = state && state.pos >= 0 ? state.pos : -1
  if (count === 0) return [loadfile(track, "replace"), ["set_property", "pause", false]]
  if (pos < 0) return [loadfile(track, "append"), ["playlist-play-index", count], ["set_property", "pause", false]]
  return [loadfile(track, "insert-next"), ["playlist-play-index", pos + 1], ["set_property", "pause", false]]
}

function playNextCommands(track) {
  return [loadfile(track, "insert-next-play")]
}

function addToQueueCommands(track) {
  return [loadfile(track, "append-play")]
}

// Replace the queue with a collection. `stop` clears mpv's playlist; loading
// everything with `append` and then jumping to the start index avoids
// resolving the first track for nothing. `start` indexes `tracks`
// (unplayable ones are skipped). With `shuffle` the order is random; with
// `keepStart` too, the start track plays first and the rest is shuffled
// (shuffle mode on and a song clicked). `originalIndex[k]` is the position
// the k-th loaded track had in the collection, so the service can restore
// that order when shuffle is turned off.
function playCollectionCommands(tracks, start, shuffle, seed, keepStart) {
  var source = tracks || []
  var playableAt = []
  for (var i = 0; i < source.length; i++) if (playable(source[i])) playableAt.push(i)
  if (playableAt.length === 0) return { commands: [], tracks: [], originalIndex: [], index: -1 }
  var wanted = Number(start) || 0
  var index = playableAt.length - 1
  for (var p = 0; p < playableAt.length; p++) {
    if (playableAt[p] >= wanted) {
      index = p
      break
    }
  }
  var positions = playableAt.map(function(_, k) { return k })
  if (shuffle) {
    if (keepStart) positions = [index].concat(shuffled(positions.filter(function(k) { return k !== index }), seed))
    else positions = shuffled(positions, seed)
    index = 0
  }
  var list = positions.map(function(k) { return source[playableAt[k]] })
  var commands = [["stop"]]
  for (var j = 0; j < list.length; j++) commands.push(loadfile(list[j], "append"))
  commands.push(["playlist-play-index", index], ["set_property", "pause", false])
  return { commands: commands, tracks: list, originalIndex: positions, index: index }
}

// mpv entry ids (as loaded) listed in the collection's own order.
function originalOrder(entryIds, originalIndex) {
  var pairs = []
  for (var i = 0; i < entryIds.length && i < originalIndex.length; i++) pairs.push([originalIndex[i], entryIds[i]])
  pairs.sort(function(a, b) { return a[0] - b[0] })
  return pairs.map(function(pair) { return pair[1] })
}

// ---- shuffle and repeat ---------------------------------------------------------

var REPEAT_MODES = ["off", "all", "one"]

function normalizeRepeat(mode) {
  return REPEAT_MODES.indexOf(mode) >= 0 ? mode : "off"
}

function nextRepeat(mode) {
  return REPEAT_MODES[(REPEAT_MODES.indexOf(normalizeRepeat(mode)) + 1) % REPEAT_MODES.length]
}

// mpv reports loop-file / loop-playlist as false, "inf", "force" or a count.
function loopOn(value) {
  return value === true || value === "inf" || value === "force" || (typeof value === "number" && value > 0)
}

function repeatMode(loopFile, loopPlaylist) {
  if (loopOn(loopFile)) return "one"
  if (loopOn(loopPlaylist)) return "all"
  return "off"
}

function repeatCommands(mode) {
  var m = normalizeRepeat(mode)
  return [["set_property", "loop-file", m === "one" ? "inf" : "no"],
          ["set_property", "loop-playlist", m === "all" ? "inf" : "no"]]
}

// Shuffle on: the entries after the current one (`pos`) in random order.
function shuffleOrder(ids, pos, seed) {
  var head = ids.slice(0, pos + 1)
  return head.concat(shuffled(ids.slice(pos + 1), seed))
}

// Shuffle off: the shuffled entries go back to their original order, in the
// slots they occupy now. Entries added since (play next, add to queue) keep
// their places.
function unshuffleOrder(ids, original) {
  var rank = {}
  for (var i = 0; i < (original || []).length; i++) rank[original[i]] = i
  var members = ids.filter(function(id) { return rank[id] !== undefined })
  members.sort(function(a, b) { return rank[a] - rank[b] })
  var k = 0
  return ids.map(function(id) { return rank[id] !== undefined ? members[k++] : id })
}

// playlist-move commands that turn the order `ids` into `target` (the same
// ids rearranged). Each step moves an entry up into place; mpv puts an entry
// moved up exactly at the target index (spike S7).
function reorderCommands(ids, target) {
  var list = ids.slice()
  var commands = []
  for (var i = 0; i < target.length; i++) {
    var j = list.indexOf(target[i])
    if (j <= i) continue
    commands.push(["playlist-move", j, i])
    list.splice(j, 1)
    list.splice(i, 0, target[i])
  }
  return commands
}

// ---- autoplay ---------------------------------------------------------------------

// Songs from YouTube Music's up-next list worth appending: playable, not in
// the queue yet (played ones included), songs before videos, at most `max`.
function autoplayPicks(queue, candidates, max) {
  var seen = {}
  for (var i = 0; i < (queue || []).length; i++) if (queue[i].videoId) seen[queue[i].videoId] = true
  var songs = []
  var videos = []
  for (var j = 0; j < (candidates || []).length; j++) {
    var track = candidates[j]
    if (!playable(track) || seen[track.videoId]) continue
    seen[track.videoId] = true
    if (track.kind === "video") videos.push(track)
    else songs.push(track)
  }
  return songs.concat(videos).slice(0, max || 10)
}

// ---- player preferences (autoplay, shuffle, repeat) --------------------------------

function parsePrefs(text) {
  var prefs = { autoplay: true, shuffle: false, repeat: "off" }
  try {
    var saved = JSON.parse(text)
    if (saved && typeof saved === "object") {
      if (typeof saved.autoplay === "boolean") prefs.autoplay = saved.autoplay
      if (typeof saved.shuffle === "boolean") prefs.shuffle = saved.shuffle
      prefs.repeat = normalizeRepeat(saved.repeat)
    }
  } catch (e) {
    // defaults
  }
  return prefs
}

// mpv inserts before the target index, so moving down needs target + 1 (S7).
function moveArgs(from, to) {
  return ["playlist-move", from, to > from ? to + 1 : to]
}

function previousCommands(timePos) {
  return Number(timePos) > 5 ? [["seek", 0, "absolute"]] : [["playlist-prev", "weak"]]
}

// ---- queue model ------------------------------------------------------------

function fallbackTrack(videoId, entry) {
  return {
    type: "track", videoId: videoId, title: String(entry.title || videoId || entry.filename || ""),
    artists: [], artistText: "", album: null, durationSec: null, thumb: null, thumbLarge: null,
    explicit: false, likeStatus: null, setVideoId: null, available: true, kind: "song", played: null
  }
}

// mpv's `playlist` property joined with the per-track metadata map.
function buildQueue(playlist, meta) {
  var out = []
  var list = playlist || []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i] || {}
    var videoId = videoIdFromUrl(entry.filename)
    var known = !!(meta && videoId && meta[videoId])
    out.push({
      index: i,
      entryId: entry.id !== undefined ? entry.id : i,
      videoId: videoId,
      current: !!entry.current,
      known: known,
      track: known ? meta[videoId] : fallbackTrack(videoId, entry)
    })
  }
  return out
}

function pruneMeta(meta, playlist) {
  var keep = {}
  var list = playlist || []
  for (var i = 0; i < list.length; i++) {
    var videoId = videoIdFromUrl(list[i] && list[i].filename)
    if (videoId && meta && meta[videoId]) keep[videoId] = meta[videoId]
  }
  return keep
}

// The queue entry with mpv's playlist entry id (end-file events carry it).
function entryById(queue, id) {
  if (id === undefined || id === null) return null
  for (var i = 0; i < (queue || []).length; i++) {
    if (queue[i].entryId === id) return queue[i]
  }
  return null
}

// What to tell you after a track failed to play. `streak` counts failures in
// a row; at 3 the service stops instead of running through the whole queue.
// `offline`: the worker couldn't reach YouTube recently either.
function playbackNotice(streak, title, detail, offline) {
  if (streak >= 3 && offline)
    return { key: "offline", title: "Can't reach YouTube Music",
             body: "Playback stopped. Check the connection, then press play to continue." }
  if (streak >= 3)
    return { key: "errors-in-a-row", title: "YouTube Music playback keeps failing",
             body: "Playback stopped. yt-dlp may need an update (omarchy update); press play to try again." }
  return { key: "play-error:" + title, title: "Couldn't play " + title, body: detail || "" }
}

function unknownVideoIds(queue, limit) {
  var ids = []
  for (var i = 0; i < (queue || []).length && ids.length < (limit || 10); i++) {
    var entry = queue[i]
    if (!entry.known && entry.videoId && ids.indexOf(entry.videoId) === -1) ids.push(entry.videoId)
  }
  return ids
}

// ---- small utilities ----------------------------------------------------------

function mulberry32(seed) {
  var state = seed >>> 0
  return function() {
    state = (state + 0x6D2B79F5) >>> 0
    var t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function shuffled(items, seed) {
  var out = (items || []).slice()
  var random = mulberry32(seed === undefined ? Date.now() : seed)
  for (var i = out.length - 1; i > 0; i--) {
    var j = Math.floor(random() * (i + 1))
    var swap = out[i]
    out[i] = out[j]
    out[j] = swap
  }
  return out
}

function formatDuration(seconds) {
  var total = Math.floor(Number(seconds))
  if (!isFinite(total) || total < 0) return ""
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var secs = total % 60
  var ss = secs < 10 ? "0" + secs : String(secs)
  if (hours > 0) return hours + ":" + (minutes < 10 ? "0" + minutes : minutes) + ":" + ss
  return minutes + ":" + ss
}

// Queue a whole list; the first track starts playback if nothing plays.
function queueAllCommands(tracks) {
  var list = (tracks || []).filter(playable)
  var commands = []
  for (var i = 0; i < list.length; i++) commands.push(loadfile(list[i], i === 0 ? "append-play" : "append"))
  return { commands: commands, tracks: list }
}

// ---- result lists ---------------------------------------------------------------
// Lists in the panel are flat arrays of rows: { header: true, title } or
// { item, trackIndex? }. trackIndex points into the list a click plays from.

var SEARCH_SECTIONS = [
  { key: "top", title: "Top result" },
  { key: "songs", title: "Songs" },
  { key: "albums", title: "Albums" },
  { key: "artists", title: "Artists" },
  { key: "playlists", title: "Playlists" },
  { key: "videos", title: "Videos" }
]

var FILTER_TITLES = { songs: "Songs", albums: "Albums", artists: "Artists", playlists: "Playlists", videos: "Videos" }

function flattenSearch(result, filter) {
  var rows = []
  if (!result) return rows
  if (filter) {
    var items = result.items || []
    if (items.length) rows.push({ header: true, title: FILTER_TITLES[filter] || "Results" })
    for (var i = 0; i < items.length; i++) rows.push({ item: items[i] })
    return rows
  }
  for (var s = 0; s < SEARCH_SECTIONS.length; s++) {
    var group = result[SEARCH_SECTIONS[s].key] || []
    if (!group.length) continue
    rows.push({ header: true, title: SEARCH_SECTIONS[s].title })
    for (var j = 0; j < group.length; j++) rows.push({ item: group[j] })
  }
  return rows
}

function trackRows(tracks) {
  var rows = []
  for (var i = 0; i < (tracks || []).length; i++) rows.push({ item: tracks[i], trackIndex: i })
  return rows
}

function flattenArtist(page) {
  var rows = []
  if (!page) return rows
  var songs = page.songs || []
  if (songs.length) {
    rows.push({ header: true, title: "Top songs" })
    for (var i = 0; i < songs.length; i++) rows.push({ item: songs[i], trackIndex: i })
  }
  var groups = [["Albums", page.albums || []], ["Singles", page.singles || []]]
  for (var g = 0; g < groups.length; g++) {
    if (!groups[g][1].length) continue
    rows.push({ header: true, title: groups[g][0] })
    for (var j = 0; j < groups[g][1].length; j++) rows.push({ item: groups[g][1][j] })
  }
  return rows
}

// The first playable track among result rows (a fresh search's likely pick).
function firstTrack(rows) {
  for (var i = 0; i < (rows || []).length; i++) {
    var row = rows[i]
    if (!row.header && row.item && row.item.type === "track" && playable(row.item)) return row.item
  }
  return null
}

// Next row a keyboard cursor may rest on (headers are skipped). From -1,
// moving down lands on the first row; at either end the cursor stays put.
function nextSelectable(rows, index, delta) {
  var count = (rows || []).length
  var step = delta < 0 ? -1 : 1
  var i = index < 0 ? (step > 0 ? -1 : count) : index
  for (var j = i + step; j >= 0 && j < count; j += step) {
    if (!rows[j].header) return j
  }
  return index
}

function joinParts(parts) {
  return parts.filter(function(part) { return part !== null && part !== undefined && String(part) !== "" }).join(" • ")
}

function itemSubtitle(item) {
  if (!item) return ""
  if (item.type === "track") return joinParts([item.artistText, item.kind === "video" ? "Video" : ""])
  if (item.type === "album") return joinParts([item.albumType, item.artistText, item.year])
  if (item.type === "playlist") return joinParts([item.author, item.count ? item.count + " songs" : ""])
  if (item.type === "artist") return item.subtitle ? item.subtitle : "Artist"
  if (item.type === "liked") return "Songs you liked"
  if (item.type === "history") return "Recently played"
  return ""
}

// Home: a header per shelf; tracks carry their index among the shelf's
// tracks so a click plays the shelf from there.
function homeRows(shelves) {
  var rows = []
  for (var s = 0; s < (shelves || []).length; s++) {
    var items = shelves[s].items || []
    if (!items.length) continue
    rows.push({ header: true, title: shelves[s].title })
    var trackIndex = 0
    for (var i = 0; i < items.length; i++) {
      var row = { item: items[i], shelfIndex: s }
      if (items[i].type === "track") row.trackIndex = trackIndex++
      rows.push(row)
    }
  }
  return rows
}

function shelfTracks(shelves, index) {
  var shelf = shelves && shelves[index]
  return shelf ? (shelf.items || []).filter(function(item) { return item.type === "track" }) : []
}

// History grouped under its "played" labels (Today, Yesterday, …).
function historyRows(tracks) {
  var rows = []
  var group = null
  for (var i = 0; i < (tracks || []).length; i++) {
    var label = tracks[i].played || "Earlier"
    if (label !== group) {
      rows.push({ header: true, title: label })
      group = label
    }
    rows.push({ item: tracks[i], trackIndex: i })
  }
  return rows
}

// ---- resume -----------------------------------------------------------------------

function sessionSnapshot(queue, index, timePos, volume, nowMs) {
  var ids = []
  var meta = {}
  for (var i = 0; i < (queue || []).length; i++) {
    var entry = queue[i]
    if (!entry.videoId) continue
    ids.push(entry.videoId)
    if (entry.known) meta[entry.videoId] = entry.track
  }
  return {
    version: 1,
    savedAt: nowMs,
    index: index,
    timePos: Math.max(0, Math.floor(Number(timePos) || 0)),
    volume: volume,
    videoIds: ids,
    meta: meta
  }
}

function parseSession(text) {
  try {
    var session = JSON.parse(text)
    return session && session.version === 1 && Array.isArray(session.videoIds) ? session : null
  } catch (e) {
    return null
  }
}

// Rebuild the saved queue and continue the saved track where it was.
function resumeCommands(session) {
  if (!session || !Array.isArray(session.videoIds) || session.videoIds.length === 0)
    return { commands: [], tracks: [], index: -1 }
  var tracks = session.videoIds.map(function(id) {
    return (session.meta && session.meta[id]) || fallbackTrack(id, {})
  })
  var index = Math.max(0, Math.min(Number(session.index) || 0, tracks.length - 1))
  var commands = [["stop"]]
  for (var i = 0; i < tracks.length; i++) {
    var command = loadfile(tracks[i], "append")
    if (i === index && session.timePos > 0)
      command[4] = (command[4] ? command[4] + "," : "") + "start=" + Math.floor(session.timePos)
    commands.push(command)
  }
  commands.push(["playlist-play-index", index], ["set_property", "pause", false])
  return { commands: commands, tracks: tracks, index: index }
}

function isSpecialPlaylist(playlist) {
  return !playlist || playlist.playlistId === "LM" || playlist.playlistId === "SE"
}

// Playlists you can add songs to.
function ownedPlaylists(playlists) {
  return (playlists || []).filter(function(p) { return p.owned && !isSpecialPlaylist(p) })
}

// The Library list: Liked Music and History, then your playlists, then saved ones.
function libraryRows(playlists) {
  var rows = [
    { item: { type: "liked", title: "Liked Music", thumb: null } },
    { item: { type: "history", title: "History", thumb: null } }
  ]
  var owned = []
  var saved = []
  for (var i = 0; i < (playlists || []).length; i++) {
    var p = playlists[i]
    if (isSpecialPlaylist(p)) continue
    if (p.owned) owned.push(p)
    else saved.push(p)
  }
  if (owned.length) rows.push({ header: true, title: "Your playlists" })
  for (var j = 0; j < owned.length; j++) rows.push({ item: owned[j] })
  if (saved.length) rows.push({ header: true, title: "Saved playlists" })
  for (var k = 0; k < saved.length; k++) rows.push({ item: saved[k] })
  return rows
}

// Remove one track from a loaded collection (by setVideoId when it has one,
// since a playlist may hold the same song twice).
function withoutTrack(page, target) {
  if (!page || !target) return page
  var next = {}
  for (var key in page) next[key] = page[key]
  var removed = false
  next.tracks = (page.tracks || []).filter(function(t) {
    if (removed) return true
    var same = target.setVideoId ? t.setVideoId === target.setVideoId : t.videoId === target.videoId
    if (same) removed = true
    return !same
  })
  if (removed && typeof page.trackCount === "number") next.trackCount = Math.max(0, page.trackCount - 1)
  return next
}

// The id a collection is loaded by, per item type.
function collectionTarget(item) {
  if (!item) return null
  if (item.type === "album") return { kind: "album", id: item.browseId }
  if (item.type === "playlist") return { kind: "playlist", id: item.playlistId }
  if (item.type === "artist") return { kind: "artist", id: item.channelId }
  if (item.type === "liked") return { kind: "liked", id: "LM" }
  if (item.type === "history") return { kind: "history", id: "history" }
  return null
}

// ---- pre-resolved streams ---------------------------------------------------------
// streams: videoId -> { url, expires } (expires in seconds since the epoch).

function streamFresh(stream, nowSec, marginSec) {
  var margin = marginSec === undefined ? 120 : marginSec
  return !!(stream && stream.url && Number(stream.expires) > nowSec + margin)
}

// Fresh streams only, at most `max` (the ones valid longest).
function pruneStreams(streams, nowSec, max) {
  var ids = Object.keys(streams || {}).filter(function(id) { return streamFresh(streams[id], nowSec) })
  ids.sort(function(a, b) { return streams[b].expires - streams[a].expires })
  var out = {}
  for (var i = 0; i < ids.length && i < (max || 50); i++) out[ids[i]] = streams[ids[i]]
  return out
}

// Upcoming queue entries (after `pos`) that still need a stream. With `wrap`
// (repeat all) the queue continues from the start.
function streamsToResolve(queue, pos, streams, nowSec, ahead, wrap) {
  var ids = []
  var count = (queue || []).length
  if (pos < 0 || count === 0) return ids
  for (var step = 1; step <= (ahead || 1); step++) {
    var i = pos + step
    if (i >= count) {
      if (!wrap) break
      i = i % count
    }
    var id = queue[i].videoId
    if (id && !streamFresh(streams && streams[id], nowSec) && ids.indexOf(id) === -1) ids.push(id)
  }
  return ids
}

// ---- recent searches and suggestions ------------------------------------------------
// Recent searches are plain strings, newest first.

function rememberQuery(list, text, max) {
  var query = String(text || "").trim()
  if (query === "") return list || []
  var key = query.toLowerCase()
  var rest = (list || []).filter(function(item) { return String(item).toLowerCase() !== key })
  return [query].concat(rest).slice(0, max || 20)
}

function forgetQuery(list, text) {
  var key = String(text || "").trim().toLowerCase()
  return (list || []).filter(function(item) { return String(item).toLowerCase() !== key })
}

function parseRecent(text) {
  try {
    var saved = JSON.parse(text)
    var queries = saved && Array.isArray(saved.queries) ? saved.queries : []
    return queries.filter(function(q) { return typeof q === "string" && q.trim() !== "" }).slice(0, 50)
  } catch (e) {
    return []
  }
}

// Up to `max` completions for what's typed: at most two of your recent
// searches that start with it, then YouTube Music's; never the typed text.
function suggestionList(recent, remote, typed, max) {
  var key = String(typed || "").trim().toLowerCase()
  var limit = max || 5
  var out = []
  var seen = {}
  seen[key] = true
  function add(text, fromHistory) {
    var value = String(text || "").trim()
    var k = value.toLowerCase()
    if (value === "" || seen[k] || out.length >= limit) return
    seen[k] = true
    out.push({ text: value, recent: fromHistory })
  }
  for (var i = 0; i < (recent || []).length && out.length < 2; i++) {
    if (String(recent[i]).toLowerCase().indexOf(key) === 0) add(recent[i], true)
  }
  for (var j = 0; j < (remote || []).length; j++) add(remote[j].text, !!remote[j].fromHistory)
  return out
}

function recentRows(recent, max) {
  var list = (recent || []).slice(0, max || 8)
  var rows = list.length ? [{ header: true, title: "Recent searches" }] : []
  for (var i = 0; i < list.length; i++) rows.push({ item: { type: "query", text: list[i], recent: true, removable: true } })
  return rows
}

// `selected` marks the one Tab put into the field.
function suggestionRows(suggestions, selected) {
  var list = suggestions || []
  var rows = list.length ? [{ header: true, title: "Suggestions" }] : []
  for (var i = 0; i < list.length; i++) {
    rows.push({ item: { type: "query", text: list[i].text, recent: !!list[i].recent, removable: false, selected: i === selected } })
  }
  return rows
}

// ---- caches ---------------------------------------------------------------------

function searchKey(query, filter) {
  return (filter || "") + "|" + String(query || "").trim().toLowerCase()
}

// Every cover URL (thumb / thumbLarge) inside a result, deduplicated.
function collectThumbs(value, max) {
  var limit = max || 150
  var seen = {}
  var out = []
  function walk(node, depth) {
    if (out.length >= limit || depth > 6 || node === null || typeof node !== "object") return
    if (Array.isArray(node)) {
      for (var i = 0; i < node.length && out.length < limit; i++) walk(node[i], depth + 1)
      return
    }
    var keys = ["thumb", "thumbLarge", "photo"]
    for (var k = 0; k < keys.length; k++) {
      var url = node[keys[k]]
      if (typeof url === "string" && url.indexOf("https://") === 0 && !seen[url]) {
        seen[url] = true
        out.push(url)
      }
    }
    for (var key in node) {
      if (node[key] && typeof node[key] === "object") walk(node[key], depth + 1)
    }
  }
  walk(value, 0)
  return out
}

// ---- bar widget -----------------------------------------------------------------

function normalizeDisplay(value) {
  var mode = String(value || "").toLowerCase()
  return mode === "player" || mode === "status" || mode === "mini" ? "player" : "icon"
}

function nextDisplay(value) {
  return normalizeDisplay(value) === "player" ? "icon" : "player"
}

// Qt.LeftButton = 1, Qt.RightButton = 2, Qt.MiddleButton = 4.
function clickAction(button) {
  if (button === 4) return "playPause"
  if (button === 2) return "toggleDisplay"
  return "panel"
}

function nowPlayingLabel(track) {
  if (!track) return ""
  var title = String(track.title || "")
  var artists = String(track.artistText || "")
  return artists ? title + "  ·  " + artists : title
}

function parseMpvLine(line) {
  try {
    var message = JSON.parse(line)
    return message && typeof message === "object" ? message : null
  } catch (e) {
    return null
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    PLUGIN_ID: PLUGIN_ID,
    trackUrl: trackUrl,
    videoIdFromUrl: videoIdFromUrl,
    mediaTitle: mediaTitle,
    utf8Length: utf8Length,
    loadfileOptions: loadfileOptions,
    playNowCommands: playNowCommands,
    playNextCommands: playNextCommands,
    addToQueueCommands: addToQueueCommands,
    playCollectionCommands: playCollectionCommands,
    originalOrder: originalOrder,
    normalizeRepeat: normalizeRepeat,
    nextRepeat: nextRepeat,
    repeatMode: repeatMode,
    repeatCommands: repeatCommands,
    shuffleOrder: shuffleOrder,
    unshuffleOrder: unshuffleOrder,
    reorderCommands: reorderCommands,
    autoplayPicks: autoplayPicks,
    parsePrefs: parsePrefs,
    moveArgs: moveArgs,
    previousCommands: previousCommands,
    buildQueue: buildQueue,
    pruneMeta: pruneMeta,
    unknownVideoIds: unknownVideoIds,
    entryById: entryById,
    playbackNotice: playbackNotice,
    shuffled: shuffled,
    formatDuration: formatDuration,
    queueAllCommands: queueAllCommands,
    flattenSearch: flattenSearch,
    trackRows: trackRows,
    flattenArtist: flattenArtist,
    nextSelectable: nextSelectable,
    firstTrack: firstTrack,
    itemSubtitle: itemSubtitle,
    collectionTarget: collectionTarget,
    ownedPlaylists: ownedPlaylists,
    libraryRows: libraryRows,
    homeRows: homeRows,
    shelfTracks: shelfTracks,
    historyRows: historyRows,
    sessionSnapshot: sessionSnapshot,
    parseSession: parseSession,
    resumeCommands: resumeCommands,
    withoutTrack: withoutTrack,
    streamFresh: streamFresh,
    pruneStreams: pruneStreams,
    streamsToResolve: streamsToResolve,
    rememberQuery: rememberQuery,
    forgetQuery: forgetQuery,
    parseRecent: parseRecent,
    suggestionList: suggestionList,
    recentRows: recentRows,
    suggestionRows: suggestionRows,
    searchKey: searchKey,
    collectThumbs: collectThumbs,
    normalizeDisplay: normalizeDisplay,
    nextDisplay: nextDisplay,
    clickAction: clickAction,
    nowPlayingLabel: nowPlayingLabel,
    parseMpvLine: parseMpvLine
  }
}
