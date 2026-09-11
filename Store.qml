import QtQuick
import Quickshell.Io
import "YtmModel.js" as Model

// Data the panel shows, kept in the service so it outlives panel unloads and
// is shared by every monitor: searches, opened collections, the library,
// likes, cover thumbnails on disk, and tab requests coming in over IPC.
//
// Collections and the library are loaded stale-while-revalidate: the worker's
// disk cache answers first (instantly), then a fresh copy replaces it.
Item {
  id: root

  property var worker: null
  // Only ask the worker for thumbnails while a panel shows them, so this
  // never starts the worker by itself.
  property bool thumbsEnabled: false

  // ---- search ---------------------------------------------------------------
  property string query: ""
  // "" = everything, grouped; otherwise a ytmusicapi search filter.
  property string filter: ""
  property var result: null
  property bool searching: false
  property string searchError: ""
  property int lastSearchMs: 0
  // The search field has keyboard focus (panel shortcuts are off then).
  property bool inputFocused: false
  property int _seq: 0
  // Recent searches: key -> { result, at }.
  readonly property int searchTtlMs: 10 * 60 * 1000
  readonly property int maxSearches: 20
  property var _searches: ({})
  readonly property int searchCacheSize: Object.keys(_searches).length

  // ---- likely picks ----------------------------------------------------------
  // A track you're likely to play next (a search's first song, the row under
  // the cursor or pointer); the service looks its stream up in advance.
  signal trackHinted(var track)

  function hint(track) {
    if (track && track.type === "track" && track.videoId) trackHinted(track)
  }

  function search(text, searchFilter) {
    var q = String(text || "").trim()
    var f = searchFilter || ""
    if (q === "") {
      _seq++
      query = ""
      result = null
      searching = false
      searchError = ""
      return
    }
    if (q === query && f === filter && (result || searching) && searchError === "") return
    var key = Model.searchKey(q, f)
    var hit = _searches[key]
    if (hit && Date.now() - hit.at < searchTtlMs) {
      _seq++
      query = q
      filter = f
      searching = false
      searchError = ""
      lastSearchMs = 0
      result = hit.result
      hint(Model.firstTrack(Model.flattenSearch(hit.result, f)))
      return
    }
    var seq = ++_seq
    var started = Date.now()
    query = q
    filter = f
    searching = true
    worker.request("search", { query: q, filter: f || null, limit: f ? 40 : 20 }, function(reply) {
      // A newer search superseded this one while it was in flight.
      if (seq !== root._seq) return
      root.searching = false
      root.lastSearchMs = Date.now() - started
      if (!reply.ok) {
        root.searchError = reply.error.message
        root.result = null
        return
      }
      root.searchError = ""
      root.result = reply.result
      root._rememberSearch(key, reply.result)
      root.requestThumbs(Model.collectThumbs(reply.result))
      root.hint(Model.firstTrack(Model.flattenSearch(reply.result, f)))
    })
  }

  // ---- recent searches -----------------------------------------------------------
  // Searches that led somewhere, newest first, in <stateDir>/searches.json.
  property string stateDir: ""
  property var recent: []
  readonly property int maxRecent: 20

  function rememberQuery(text) {
    var next = Model.rememberQuery(recent, text, maxRecent)
    if (JSON.stringify(next) === JSON.stringify(recent)) return
    recent = next
    _saveRecent()
  }

  function forgetQuery(text) {
    recent = Model.forgetQuery(recent, text)
    _saveRecent()
  }

  function _saveRecent() {
    if (stateDir !== "") recentFile.setText(JSON.stringify({ version: 1, queries: recent }) + "\n")
  }

  FileView {
    id: recentFile
    path: root.stateDir !== "" ? root.stateDir + "/searches.json" : ""
    atomicWrites: true
    watchChanges: false
    printErrors: false
    onLoaded: root.recent = Model.parseRecent(text())
  }

  // ---- suggestions while typing ------------------------------------------------------
  // [{ text, recent }] for the text being typed: matching recent searches,
  // then YouTube Music's. One request at a time (the latest text wins);
  // answers are kept for the session, so backspacing asks nothing.
  property var suggestions: []
  property string _suggestFor: ""
  property bool _suggesting: false
  property var _suggestCache: ({})

  function suggest(text) {
    var q = String(text || "").trim()
    _suggestFor = q
    if (q === "") {
      suggestions = []
      return
    }
    var cached = _suggestCache[q.toLowerCase()]
    suggestions = Model.suggestionList(recent, cached || [], q, 5)
    if (cached || _suggesting || !worker) return
    _suggesting = true
    worker.request("suggestions", { query: q }, function(reply) {
      root._suggesting = false
      if (reply.ok) root._cacheSuggestions(q, reply.result.items || [])
      if (root._suggestFor !== q) root.suggest(root._suggestFor)
      else if (reply.ok) root.suggestions = Model.suggestionList(root.recent, reply.result.items || [], q, 5)
    }, 5000)
  }

  function _cacheSuggestions(q, items) {
    var keys = Object.keys(_suggestCache)
    var next = ({})
    for (var i = Math.max(0, keys.length - 49); i < keys.length; i++) next[keys[i]] = _suggestCache[keys[i]]
    next[q.toLowerCase()] = items
    _suggestCache = next
  }

  function _rememberSearch(key, value) {
    var keys = Object.keys(_searches).filter(function(k) { return k !== key })
    keys.sort(function(a, b) { return root._searches[b].at - root._searches[a].at })
    var next = ({})
    for (var i = 0; i < keys.length && i < maxSearches - 1; i++) next[keys[i]] = _searches[keys[i]]
    next[key] = { result: value, at: Date.now() }
    _searches = next
  }

  // ---- collections (album / playlist / liked / artist pages) -------------------
  readonly property int collectionTtlMs: 5 * 60 * 1000
  readonly property int maxCollections: 5
  property var _collections: ({})

  function collectionKey(kind, id) {
    return kind + ":" + id
  }

  // `callback` may run twice: with the disk-cached copy, then the fresh one.
  function loadCollection(kind, id, callback) {
    var key = collectionKey(kind, id)
    var entry = _collections[key]
    if (entry && Date.now() - entry.at < collectionTtlMs) {
      callback({ ok: true, result: entry.data })
      return
    }
    var method = kind === "album" ? "album" : kind === "artist" ? "artist" : kind === "liked" ? "liked"
      : kind === "history" ? "history" : "playlist"
    var params = kind === "album" ? { browseId: id } : kind === "artist" ? { channelId: id }
      : kind === "liked" ? ({}) : kind === "history" ? { limit: 100 } : { playlistId: id }
    _cachedThenFresh(method, params, function(reply) {
      if (reply.ok) {
        reply = { ok: true, cached: reply.cached, result: root._asCollection(kind, reply.result) }
        root._remember(key, reply.result)
        root.requestThumbs(Model.collectThumbs(reply.result))
      }
      callback(reply)
    })
  }

  // History comes back as a plain list; pages want a collection.
  function _asCollection(kind, result) {
    if (kind !== "history") return result
    var items = result.items || []
    return {
      type: "collection", kind: "history", id: "history", playlistId: null,
      title: "History", subtitle: items.length + " songs", owned: false, editable: false,
      trackCount: items.length, truncated: false,
      thumb: items.length ? items[0].thumb : null, thumbLarge: items.length ? items[0].thumbLarge : null,
      tracks: items
    }
  }

  // ---- home ---------------------------------------------------------------------
  readonly property int homeTtlMs: 10 * 60 * 1000
  property var shelves: []
  property bool homeLoading: false
  property string homeError: ""
  property real homeAt: 0

  function loadHome(force) {
    if (homeLoading) return
    if (!force && homeAt > 0 && Date.now() - homeAt < homeTtlMs) return
    homeLoading = true
    homeError = ""
    var handle = function(reply) {
      root.homeLoading = false
      if (!reply.ok) {
        if (root.shelves.length === 0) root.homeError = reply.error.message
        return
      }
      root.homeError = ""
      root.shelves = reply.result.shelves || []
      root.homeAt = Date.now()
      root.requestThumbs(Model.collectThumbs(root.shelves))
    }
    if (force) worker.request("home", { limit: 6, cache: "refresh" }, handle, 30000)
    else _cachedThenFresh("home", { limit: 6 }, handle)
  }

  // Ask with cache "prefer"; if that came from disk, follow up with a refresh.
  function _cachedThenFresh(method, params, handle) {
    var first = ({})
    for (var k in params) first[k] = params[k]
    first.cache = "prefer"
    worker.request(method, first, function(reply) {
      handle(reply)
      if (!reply.ok || !reply.cached) return
      var fresh = ({})
      for (var j in params) fresh[j] = params[j]
      fresh.cache = "refresh"
      worker.request(method, fresh, function(update) {
        if (update.ok) handle(update)
      }, 30000)
    }, 30000)
  }

  function forgetCollection(kind, id) {
    var key = collectionKey(kind, id)
    if (!_collections[key]) return
    var next = ({})
    for (var k in _collections) if (k !== key) next[k] = _collections[k]
    _collections = next
  }

  function _remember(key, data) {
    var others = Object.keys(_collections).filter(function(k) { return k !== key })
    others.sort(function(a, b) { return root._collections[b].at - root._collections[a].at })
    var next = ({})
    for (var i = 0; i < others.length && i < maxCollections - 1; i++) next[others[i]] = _collections[others[i]]
    next[key] = { data: data, at: Date.now() }
    _collections = next
  }

  // ---- library ------------------------------------------------------------------
  readonly property int libraryTtlMs: 5 * 60 * 1000
  property var playlists: []
  property bool libraryLoading: false
  property string libraryError: ""
  property real libraryAt: 0

  // force: skip both the memory and the disk cache (after an edit).
  function loadLibrary(force) {
    if (libraryLoading) return
    if (!force && libraryAt > 0 && Date.now() - libraryAt < libraryTtlMs) return
    libraryLoading = true
    libraryError = ""
    var handle = function(reply) {
      root.libraryLoading = false
      if (!reply.ok) {
        if (root.playlists.length === 0) root.libraryError = reply.error.message
        return
      }
      root.libraryError = ""
      root.playlists = reply.result.items || []
      root.libraryAt = Date.now()
      root.requestThumbs(Model.collectThumbs(root.playlists))
    }
    if (force) worker.request("libraryPlaylists", { limit: 200, cache: "refresh" }, handle, 30000)
    else _cachedThenFresh("libraryPlaylists", { limit: 200 }, handle)
  }

  function invalidateLibrary() {
    libraryAt = 0
  }

  // ---- likes (videoId -> "LIKE" | "INDIFFERENT" | "DISLIKE") -----------------------
  property var likes: ({})

  function likeStatus(videoId, fallback) {
    var known = likes[videoId]
    return known !== undefined ? known : (fallback === undefined ? null : fallback)
  }

  function setLike(videoId, status) {
    var next = ({})
    for (var key in likes) next[key] = likes[key]
    next[videoId] = status
    likes = next
  }

  // ---- cover thumbnails on disk (url -> local path) ------------------------------
  readonly property int maxThumbs: 2000
  property var thumbs: ({})
  property var _thumbRequested: ({})
  readonly property int thumbCount: Object.keys(thumbs).length

  function thumbSource(url) {
    if (!url) return ""
    var path = thumbs[url]
    return path ? "file://" + path : url
  }

  function requestThumbs(urls) {
    if (!thumbsEnabled || !worker) return
    var wanted = []
    for (var i = 0; i < (urls || []).length; i++) {
      var url = urls[i]
      if (url && !thumbs[url] && !_thumbRequested[url]) {
        _thumbRequested[url] = true
        wanted.push(url)
      }
    }
    for (var start = 0; start < wanted.length; start += 150) {
      worker.request("cacheThumbs", { urls: wanted.slice(start, start + 150) }, function(reply) {
        if (reply.ok) root.mergeThumbs(reply.result.paths || {})
      })
    }
  }

  function mergeThumbs(paths) {
    var next = null
    for (var url in paths) {
      if (thumbs[url] === paths[url]) continue
      if (!next) {
        next = ({})
        var keys = Object.keys(thumbs)
        // Keep the map bounded; the files themselves are pruned by the worker.
        for (var i = Math.max(0, keys.length - maxThumbs + 200); i < keys.length; i++) next[keys[i]] = thumbs[keys[i]]
      }
      next[url] = paths[url]
    }
    if (next) thumbs = next
  }

  Connections {
    target: root.worker
    function onEventReceived(message) {
      if (message.event === "thumbs") root.mergeThumbs(message.paths || {})
    }
  }

  // Signing in or out: nothing cached belongs to the new session.
  function reset() {
    _collections = ({})
    _searches = ({})
    playlists = []
    libraryAt = 0
    libraryError = ""
    shelves = []
    homeAt = 0
    homeError = ""
    likes = ({})
  }

  // ---- tab requests (IPC "search" opens the panel on the search tab) -----------
  property string requestedTab: ""
  property int tabRequestSeq: 0

  function requestTab(tab) {
    requestedTab = tab
    tabRequestSeq++
  }
}
