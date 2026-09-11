import QtQuick
import Quickshell
import Quickshell.Io
import "YtmModel.js" as Model

// Single service instance for damir.ytmusic. Playback state is mirrored from
// the detached mpv player (which owns the queue and per-track metadata, so
// both survive plugin reloads); library/search calls go to the ytmusicapi
// worker. Bar widgets, one per monitor, reach this via
// bar.shell.serviceFor("damir.ytmusic").
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: Model.PLUGIN_ID
  readonly property string version: manifest && manifest.version ? String(manifest.version) : "0.0.0"

  // The shell strips manifest.__sourceDir for third-party plugins, so the
  // plugin locates its own files relative to this QML file instead.
  readonly property string rootDir: localPath(Qt.resolvedUrl("."))

  // When this instance was created; tells hot-reloaded instances apart.
  readonly property real startedAt: Date.now()

  // ---- playback state (mirrored from mpv) -------------------------------------
  readonly property string mpvState: mpv.mpvState
  property bool paused: false
  property bool idle: true
  property bool buffering: false
  property int playlistPos: -1
  property int playlistCount: 0
  property string mediaTitle: ""
  property real duration: 0
  property real position: 0
  property int volume: 100
  property var playlist: []
  // videoId -> Track; mirrored into mpv's user-data/ytm/meta.
  property var meta: ({})

  // ---- player modes -------------------------------------------------------------
  // Saved in ~/.cache/omarchy-ytmusic/player.json. Repeat lives in mpv
  // (loop-file / loop-playlist, so MPRIS sees it too) and is mirrored here;
  // the saved value is applied whenever a fresh player starts.
  property bool autoplay: true
  property bool shuffle: false
  property string repeatPref: "off"
  property bool prefsLoaded: false
  property var _loopFile: false
  property var _loopPlaylist: false
  readonly property string repeatMode: mpv.up ? Model.repeatMode(_loopFile, _loopPlaylist) : repeatPref
  // mpv entry ids in their order before shuffling; mirrored into mpv's
  // user-data/ytm/order so turning shuffle off works after a plugin reload.
  property var shuffleOrder: []
  property bool _reordering: false

  // videoId -> { url, expires }: streams resolved ahead of time by the worker,
  // mirrored into mpv's user-data/ytm/streams where mpv/ytm-streams.lua plays
  // them (~0.3 s to audio instead of ~2 s through yt-dlp).
  property var streams: ({})
  property var _resolving: ({})
  property int resolvingCount: 0
  // A "play now" waiting for its stream: { token, title, run }.
  property var _pendingPlay: null
  property int _playToken: 0
  readonly property string pendingTitle: _pendingPlay ? _pendingPlay.title : ""
  property string lastError: ""

  readonly property var queue: Model.buildQueue(playlist, meta)
  readonly property var currentEntry: playlistPos >= 0 && playlistPos < queue.length ? queue[playlistPos] : null
  readonly property var currentTrack: currentEntry ? currentEntry.track : null
  readonly property bool hasMedia: mpv.up && !idle && currentEntry !== null
  readonly property bool playing: hasMedia && !paused

  // Open panels (one per monitor at most). The position is only polled while
  // one shows it; otherwise time-pos would wake the shell every second.
  property int panelsOpen: 0
  readonly property bool positionWanted: panelsOpen > 0

  readonly property string workerState: backend.workerState

  // ---- account ----------------------------------------------------------------
  // The shell only ever reads account.json (display name/handle/photo). The
  // session itself stays in files only the worker and mpv read.
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy-ytmusic"
  property var account: null
  // signedOut | ok | expired | invalid
  readonly property string authState: account === null ? "signedOut"
    : backend.auth === "expired" ? "expired"
    : backend.auth === "invalid" ? "invalid"
    : "ok"
  readonly property bool signedIn: authState === "ok"
  property bool expiryNotified: false
  readonly property string currentLike: currentTrack ? storeItem.likeStatus(currentTrack.videoId, currentTrack.likeStatus) : ""

  property var _lookedUp: ({})

  function localPath(url) {
    var path = String(url || "")
    if (path.indexOf("file://") === 0) path = decodeURIComponent(path.slice(7))
    return path.replace(/\/+$/, "")
  }

  function fail(message) {
    lastError = message
    console.warn("ytmusic: " + message)
  }

  // ---- queue actions ---------------------------------------------------------------

  function remember(tracks) {
    var next = ({})
    for (var key in meta) next[key] = meta[key]
    var changed = false
    for (var i = 0; i < tracks.length; i++) {
      var track = tracks[i]
      if (track && track.videoId) {
        next[track.videoId] = track
        changed = true
      }
    }
    if (!changed) return
    meta = next
    metaSync.restart()
    storeItem.requestThumbs(Model.collectThumbs(tracks))
  }

  function playNow(track) {
    if (!track || !track.videoId) return false
    remember([track])
    withStream(track, function() {
      mpv.commands(Model.playNowCommands(track, { count: root.playlistCount, pos: root.playlistPos }))
    })
    return true
  }

  // ---- streams -------------------------------------------------------------------

  function nowSec() {
    return Date.now() / 1000
  }

  function streamFor(videoId) {
    var stream = streams[videoId]
    return Model.streamFresh(stream, nowSec()) ? stream : null
  }

  function resolveStream(videoId, callback) {
    if (!videoId) return
    if (streamFor(videoId)) {
      if (callback) callback(true)
      return
    }
    if (_resolving[videoId]) {
      if (callback) _resolving[videoId].push(callback)
      return
    }
    _resolving[videoId] = callback ? [callback] : []
    resolvingCount++
    backend.request("resolve", { videoId: videoId }, function(reply) {
      var waiting = root._resolving[videoId] || []
      delete root._resolving[videoId]
      root.resolvingCount = Math.max(0, root.resolvingCount - 1)
      if (reply.ok) root.addStream(videoId, reply.result)
      else console.warn("ytmusic: no stream for " + videoId + ": " + reply.error.message)
      for (var i = 0; i < waiting.length; i++) waiting[i](reply.ok)
      root.releaseWorkerIfIdle()
    }, 20000)
  }

  // ---- likely picks -------------------------------------------------------------------
  // While a panel is open, the stream of what you'll probably play next (a
  // search's first song, the row under the cursor or pointer) is looked up in
  // the background, so Enter or a click starts in ~0.3 s instead of ~1.5 s.
  // One lookup at a time (the latest hint wins), at most 30 per opening.
  property string _speculating: ""
  property var _speculateNext: null
  property int speculated: 0

  function speculate(track) {
    if (panelsOpen === 0 || !track || !track.videoId || track.available === false) return
    if (streamFor(track.videoId) || _resolving[track.videoId]) return
    if (_speculating !== "") {
      _speculateNext = track
      return
    }
    if (speculated >= 30) return
    speculated++
    _speculating = track.videoId
    resolveStream(track.videoId, function() {
      root._speculating = ""
      var next = root._speculateNext
      root._speculateNext = null
      if (next) root.speculate(next)
    })
  }

  // Background pre-resolving shouldn't keep the worker (~80 MiB with yt-dlp
  // loaded) around for its full idle timeout when nobody is browsing.
  function releaseWorkerIfIdle() {
    if (panelsOpen === 0 && !_pendingPlay && resolvingCount === 0) backend.release(20000)
  }

  function addStream(videoId, stream) {
    var next = Model.pruneStreams(streams, nowSec(), 50)
    next[videoId] = { url: stream.url, expires: stream.expires }
    streams = next
    pushStreams()
  }

  function dropStreams(ids) {
    var next = ({})
    for (var key in streams) if (ids.indexOf(key) === -1) next[key] = streams[key]
    streams = next
  }

  // Sent before any loadfile that needs them: commands on the socket run in order.
  function pushStreams() {
    if (mpv.up) mpv.command(["set_property", "user-data/ytm/streams", Model.pruneStreams(streams, nowSec(), 50)])
  }

  // Run `start` once the track's stream is resolved (or after a failure or
  // 10 s, when mpv resolves it through yt-dlp itself). Only the latest runs.
  function withStream(track, start) {
    if (streamFor(track.videoId)) {
      pushStreams()
      start()
      return
    }
    var token = ++_playToken
    _pendingPlay = { token: token, title: track.title || "", run: start }
    pendingFallback.restart()
    resolveStream(track.videoId, function() { root.runPendingPlay(token) })
  }

  function runPendingPlay(token) {
    if (!_pendingPlay || _pendingPlay.token !== token) return
    var run = _pendingPlay.run
    _pendingPlay = null
    pendingFallback.stop()
    run()
  }

  function preResolveUpcoming() {
    if (repeatMode === "one") return
    var ids = Model.streamsToResolve(queue, playlistPos, streams, nowSec(), 1, repeatMode === "all")
    for (var i = 0; i < ids.length; i++) resolveStream(ids[i])
  }

  // ---- shuffle and repeat ------------------------------------------------------------

  function savePrefs() {
    prefsFile.setText(JSON.stringify({ version: 1, autoplay: autoplay, shuffle: shuffle, repeat: repeatPref }) + "\n")
  }

  function applyPrefs(text) {
    var prefs = Model.parsePrefs(text)
    autoplay = prefs.autoplay
    shuffle = prefs.shuffle
    repeatPref = prefs.repeat
    prefsLoaded = true
    applyRepeat()
  }

  // A player that just started has mpv's defaults (no looping).
  function applyRepeat() {
    if (prefsLoaded && mpv.up) mpv.commands(Model.repeatCommands(repeatPref))
  }

  function setRepeat(mode) {
    repeatPref = Model.normalizeRepeat(mode)
    savePrefs()
    applyRepeat()
    return true
  }

  // off → all → one → off
  function cycleRepeat() {
    return setRepeat(Model.nextRepeat(repeatMode))
  }

  function setShuffleOrder(ids) {
    shuffleOrder = ids
    if (mpv.up) mpv.command(["set_property", "user-data/ytm/order", ids])
  }

  // On: the songs after the current one play in random order. Off: they go
  // back to the order they had (songs added meanwhile keep their places).
  function setShuffle(on) {
    if (_reordering) return false
    shuffle = !!on
    savePrefs()
    if (!mpv.up || playlistCount < 2) {
      setShuffleOrder([])
      return true
    }
    _reordering = true
    mpv.command(["get_property", "playlist"], function(reply) {
      root._reordering = false
      if (!reply || reply.error !== "success" || !Array.isArray(reply.data)) return
      var ids = reply.data.map(function(entry) { return entry.id })
      var pos = -1
      for (var i = 0; i < reply.data.length; i++) if (reply.data[i].current) pos = i
      if (root.shuffle) {
        root.setShuffleOrder(ids)
        mpv.commands(Model.reorderCommands(ids, Model.shuffleOrder(ids, pos, Date.now())))
      } else {
        mpv.commands(Model.reorderCommands(ids, Model.unshuffleOrder(ids, root.shuffleOrder)))
        root.setShuffleOrder([])
      }
      // Moves change neither playlist-count nor playlist-pos, so nothing
      // observed would announce them.
      root.refreshQueue()
    })
    return true
  }

  function toggleShuffle() {
    return setShuffle(!shuffle)
  }

  // ---- autoplay ------------------------------------------------------------------------
  // A few seconds into the last song of the queue, YouTube Music's up-next
  // list for it is appended (songs before videos, nothing already queued),
  // so the music keeps going as on music.youtube.com. Not while repeating.
  readonly property bool autoplayWanted: autoplay && repeatMode === "off" && hasMedia && playlistPos === playlistCount - 1
  property string _autoplaySeed: ""

  onAutoplayWantedChanged: {
    if (autoplayWanted) autoplayTimer.restart()
    else autoplayTimer.stop()
  }

  function setAutoplay(on) {
    autoplay = !!on
    savePrefs()
    return true
  }

  function toggleAutoplay() {
    return setAutoplay(!autoplay)
  }

  function refillAutoplay() {
    var seed = currentTrack
    if (!autoplayWanted || !seed || !seed.videoId || seed.videoId === _autoplaySeed) return
    _autoplaySeed = seed.videoId
    backend.request("upNext", { videoId: seed.videoId }, function(reply) {
      root.releaseWorkerIfIdle()
      if (!reply.ok) {
        console.warn("ytmusic: autoplay: " + reply.error.message)
        root._autoplaySeed = ""
        return
      }
      // Still at the end of the queue (or it just ran out)? Then append; the
      // first song starts playback if the queue already ended.
      var ended = root.autoplay && root.repeatMode === "off" && root.idle && root.playlistCount > 0
      if (!root.autoplayWanted && !ended) return
      root.queueAll(Model.autoplayPicks(root.queue, reply.result.items || [], 10))
    }, 20000)
  }

  onPlaylistPosChanged: {
    preResolve.restart()
    sessionSave.restart()
  }
  onPlaylistChanged: {
    preResolve.restart()
    sessionSave.restart()
  }
  onPausedChanged: if (paused) saveSession()

  // ---- resume ----------------------------------------------------------------------
  // The queue, position and volume are saved to ~/.cache/omarchy-ytmusic/
  // session.json, so play/pause can bring everything back after mpv quit
  // (idle timeout, logout, reboot).
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy-ytmusic"
  property var session: null
  readonly property bool canResume: !mpv.up && !!session && session.videoIds.length > 0
  readonly property string resumeTitle: {
    if (!session || !session.meta) return ""
    var track = session.meta[session.videoIds[session.index]]
    return track ? Model.mediaTitle(track) : ""
  }

  function saveSession() {
    if (!mpv.up || playlistPos < 0 || queue.length === 0) return
    mpv.command(["get_property", "time-pos"], function(reply) {
      var pos = reply && typeof reply.data === "number" ? reply.data : root.position
      var snapshot = Model.sessionSnapshot(root.queue, root.playlistPos, pos, root.volume, Date.now())
      root.session = snapshot
      sessionFile.setText(JSON.stringify(snapshot) + "\n")
    })
  }

  function resume() {
    if (!canResume) return false
    var plan = Model.resumeCommands(session)
    if (plan.tracks.length === 0) return false
    if (typeof session.volume === "number") volume = session.volume
    remember(plan.tracks)
    // The snapshot keeps the queue as it was (shuffled or not), so turning
    // shuffle off afterwards keeps that order.
    withStream(plan.tracks[plan.index], function() {
      mpv.commands(plan.commands)
      root.setShuffleOrder([])
    })
    return true
  }

  // ---- playback error notices --------------------------------------------------------
  // Delayed a few seconds: mpv/ytm-streams.lua silently retries an expired
  // pre-resolved stream, and a retry that works is not worth a notification.
  property int consecutiveErrors: 0
  property var _notifiedAt: ({})
  property var _pendingNotice: null

  function notifyOnce(key, title, body, windowMs) {
    var now = Date.now()
    var last = _notifiedAt[key]
    if (last && now - last < (windowMs || 600000)) return
    var next = ({})
    for (var k in _notifiedAt) next[k] = _notifiedAt[k]
    next[key] = now
    _notifiedAt = next
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "YouTube Music", title, body || ""])
  }

  // Where play/pause continues after failures stopped playback: the first
  // track of the current run of failures.
  property int _retryIndex: -1

  function queueErrorNotice(title, detail) {
    consecutiveErrors++
    var offline = backend.lastNetworkErrorAt > 0 && Date.now() - backend.lastNetworkErrorAt < 120000
    _pendingNotice = Model.playbackNotice(consecutiveErrors, title, detail, offline)
    errorNotice.restart()
  }

  function playNext(track) {
    if (!track || !track.videoId) return false
    remember([track])
    mpv.commands(Model.playNextCommands(track))
    return true
  }

  function addToQueue(track) {
    if (!track || !track.videoId) return false
    remember([track])
    mpv.commands(Model.addToQueueCommands(track))
    return true
  }

  // Replace the queue with `tracks`, starting at `start`. With shuffle mode
  // on, that song plays first and the rest is shuffled. `shuffleAll` (the
  // Shuffle button) turns shuffle mode on and starts anywhere.
  function playCollection(tracks, start, shuffleAll) {
    if (shuffleAll && !shuffle) {
      shuffle = true
      savePrefs()
    }
    var random = shuffle
    var plan = Model.playCollectionCommands(tracks || [], start || 0, random, Date.now(), !shuffleAll)
    if (plan.tracks.length === 0) return false
    remember(plan.tracks)
    withStream(plan.tracks[plan.index], function() {
      mpv.commands(plan.commands)
      if (!random) {
        root.setShuffleOrder([])
        return
      }
      mpv.command(["get_property", "playlist"], function(reply) {
        if (reply && reply.error === "success" && Array.isArray(reply.data))
          root.setShuffleOrder(Model.originalOrder(reply.data.map(function(entry) { return entry.id }), plan.originalIndex))
      })
    })
    return true
  }

  function queueAll(tracks) {
    var plan = Model.queueAllCommands(tracks || [])
    if (plan.tracks.length === 0) return false
    remember(plan.tracks)
    mpv.commands(plan.commands)
    return true
  }

  // ---- account actions ------------------------------------------------------------

  function signInCommand() {
    return "'" + rootDir + "/bin/ytm' auth"
  }

  function signIn() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", signInCommand()])
    return true
  }

  // `ytm logout` deletes the session files and asks this service to reload.
  function signOut() {
    Quickshell.execDetached([rootDir + "/bin/ytm", "logout"])
    return true
  }

  function setAccount(text) {
    var parsed = null
    try {
      parsed = text ? JSON.parse(text) : null
    } catch (e) {
      parsed = null
    }
    var changed = JSON.stringify(parsed) !== JSON.stringify(account)
    account = parsed
    if (changed) applyAuthChange()
  }

  function applyAuthChange() {
    storeItem.reset()
    expiryNotified = false
    if (backend.workerState === "stopped") backend.auth = account ? "unknown" : "none"
    else backend.request("reloadAuth", ({}))
  }

  // Called by `ytm auth` / `ytm logout` over IPC after they change the files.
  function reloadAuth() {
    accountFile.reload()
    applyAuthChange()
    return true
  }

  function notify(title, body) {
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "YouTube Music", "-t", "2500", title, body || ""])
  }

  onAuthStateChanged: {
    if ((authState === "expired" || authState === "invalid") && !expiryNotified) {
      expiryNotified = true
      Quickshell.execDetached(["omarchy-notification-send", "--app-name", "YouTube Music",
        "YouTube Music sign-in expired", "Click to sign in again (or use the Library tab).",
        "--exec", "omarchy-launch-floating-terminal-with-presentation", signInCommand()])
    }
  }

  // ---- likes -------------------------------------------------------------------------

  function likeStatusOf(track) {
    return track ? storeItem.likeStatus(track.videoId, track.likeStatus) : null
  }

  function setLike(track, like) {
    if (!track || !track.videoId) return false
    if (!signedIn) {
      fail("Sign in to like songs")
      return false
    }
    var previous = likeStatusOf(track)
    var rating = like ? "LIKE" : "INDIFFERENT"
    storeItem.setLike(track.videoId, rating)
    backend.request("rate", { videoId: track.videoId, rating: rating }, function(reply) {
      if (!reply.ok) {
        storeItem.setLike(track.videoId, previous)
        root.fail(reply.error.message)
        return
      }
      storeItem.forgetCollection("liked", "LM")
      root.notify(like ? "Liked" : "Removed from Liked Music", Model.mediaTitle(track))
    })
    return true
  }

  function toggleLike(track) {
    return setLike(track, likeStatusOf(track) !== "LIKE")
  }

  // Only looked up while a panel shows it; results are cached per videoId.
  function refreshLikeStatus() {
    var track = currentTrack
    if (!signedIn || !track || likeStatusOf(track) !== null) return
    backend.request("likeStatus", { videoId: track.videoId }, function(reply) {
      if (reply.ok && reply.result.likeStatus) storeItem.setLike(track.videoId, reply.result.likeStatus)
    })
  }

  onCurrentTrackChanged: if (positionWanted) likeCheck.restart()

  // ---- playlists ---------------------------------------------------------------------

  function createPlaylist(title, tracks, callback) {
    var name = String(title || "").trim()
    if (!signedIn || name === "") return false
    var ids = (tracks || []).filter(function(t) { return t && t.videoId }).map(function(t) { return t.videoId })
    backend.request("createPlaylist", { title: name, videoIds: ids.length ? ids : null }, function(reply) {
      if (reply.ok) {
        storeItem.loadLibrary(true)
        root.notify("Playlist created", ids.length ? name + " — " + ids.length + (ids.length === 1 ? " song" : " songs") : name)
      } else {
        root.fail(reply.error.message)
      }
      if (callback) callback(reply)
    }, 30000)
    return true
  }

  function addToPlaylist(playlist, tracks, callback) {
    var list = (tracks || []).filter(function(t) { return t && t.videoId })
    if (!signedIn || !playlist || list.length === 0) return false
    backend.request("addToPlaylist", { playlistId: playlist.playlistId, videoIds: list.map(function(t) { return t.videoId }) }, function(reply) {
      if (reply.ok) {
        storeItem.forgetCollection("playlist", playlist.playlistId)
        root.notify("Added to " + playlist.title, list.length === 1 ? Model.mediaTitle(list[0]) : list.length + " songs")
      } else {
        root.fail(reply.error.message)
      }
      if (callback) callback(reply)
    }, 30000)
    return true
  }

  function removeFromPlaylist(playlistId, tracks, callback) {
    var items = (tracks || []).filter(function(t) { return t && t.setVideoId })
      .map(function(t) { return { videoId: t.videoId, setVideoId: t.setVideoId } })
    if (!signedIn || !playlistId || items.length === 0) return false
    backend.request("removeFromPlaylist", { playlistId: playlistId, items: items }, function(reply) {
      if (reply.ok) storeItem.forgetCollection("playlist", playlistId)
      else root.fail(reply.error.message)
      if (callback) callback(reply)
    }, 30000)
    return true
  }

  function deletePlaylist(playlist, callback) {
    if (!signedIn || !playlist || !playlist.playlistId) return false
    backend.request("deletePlaylist", { playlistId: playlist.playlistId }, function(reply) {
      if (reply.ok) {
        storeItem.forgetCollection("playlist", playlist.playlistId)
        storeItem.loadLibrary(true)
        root.notify("Playlist deleted", playlist.title || "")
      } else {
        root.fail(reply.error.message)
      }
      if (callback) callback(reply)
    }, 30000)
    return true
  }

  // Open the panel on the search tab with results for `query`.
  function showSearch(query) {
    var text = String(query || "").trim()
    if (text !== "") store.search(text, "")
    store.requestTab("search")
    if (shell && typeof shell.summon === "function") shell.summon(pluginId)
    return true
  }

  // ---- transport ------------------------------------------------------------

  function playPause() {
    if (!mpv.up) return canResume ? resume() : false
    if (idle && playlistCount > 0) {
      var start = _retryIndex >= 0 && _retryIndex < playlistCount ? _retryIndex : 0
      mpv.commands([["playlist-play-index", start], ["set_property", "pause", false]])
    }
    else if (!idle) mpv.command(["cycle", "pause"])
    else return false
    return true
  }

  function next() {
    if (!hasMedia) return false
    mpv.command(["playlist-next", "weak"])
    return true
  }

  function previous() {
    if (!hasMedia) return false
    mpv.command(["get_property", "time-pos"], function(reply) {
      mpv.commands(Model.previousCommands(reply && reply.data))
    })
    return true
  }

  function seek(seconds) {
    if (!hasMedia) return false
    position = Math.max(0, Number(seconds) || 0)
    mpv.command(["seek", position, "absolute"])
    return true
  }

  function seekRelative(delta) {
    if (!hasMedia) return false
    mpv.command(["seek", Number(delta) || 0, "relative"], function() { root.fetchPosition() })
    return true
  }

  function fetchPosition() {
    if (!mpv.up) return
    mpv.command(["get_property", "time-pos"], function(reply) {
      if (reply && typeof reply.data === "number") root.position = reply.data
    })
  }

  function panelOpenChanged(isOpen) {
    panelsOpen = Math.max(0, panelsOpen + (isOpen ? 1 : -1))
    // Start the worker and load yt-dlp while you look around, so the first
    // search, library load and play from the panel are warm.
    if (isOpen) {
      speculated = 0
      checkTools()
      backend.request("warmStreams", ({}))
    }
  }

  onPositionWantedChanged: {
    if (!positionWanted) return
    fetchPosition()
    likeCheck.restart()
  }

  function setVolume(percent) {
    volume = Math.max(0, Math.min(130, Math.round(Number(percent) || 0)))
    if (mpv.up) mpv.command(["set_property", "volume", volume])
    return true
  }

  function stop() {
    if (!mpv.up) return false
    mpv.command(["stop"])
    return true
  }

  function jumpTo(index) {
    if (!mpv.up || index < 0 || index >= playlistCount) return false
    var entry = queue[index]
    var jump = function() { mpv.commands([["playlist-play-index", index], ["set_property", "pause", false]]) }
    if (entry && entry.videoId) withStream(entry.track, jump)
    else jump()
    return true
  }

  function removeAt(index) {
    if (!mpv.up || index < 0 || index >= playlistCount) return false
    mpv.command(["playlist-remove", index])
    return true
  }

  function move(from, to) {
    if (!mpv.up || from === to || from < 0 || to < 0 || from >= playlistCount || to >= playlistCount) return false
    mpv.command(Model.moveArgs(from, to))
    // A move changes neither playlist-count nor playlist-pos (unless it
    // moves the current entry), so fetch the new order.
    refreshQueue()
    return true
  }

  // Keeps the current track, drops everything else.
  function clearUpcoming() {
    if (!mpv.up) return false
    mpv.command(["playlist-clear"])
    return true
  }

  // Search songs and play the best match now, next, or at the end of the
  // queue (mode "now" | "next" | "queue"). Used by IPC.
  function playQuery(query, mode) {
    var text = String(query || "").trim()
    if (text === "") return false
    backend.request("search", { query: text, filter: "songs", limit: 5 }, function(reply) {
      if (!reply.ok) {
        root.fail(reply.error.message)
        return
      }
      var items = reply.result.items || []
      var track = null
      for (var i = 0; i < items.length && !track; i++) if (items[i].available !== false) track = items[i]
      if (!track) {
        root.fail("No songs found for \"" + text + "\"")
        return
      }
      if (mode === "queue") root.addToQueue(track)
      else if (mode === "next") root.playNext(track)
      else root.playNow(track)
    })
    return true
  }

  // ---- mirroring mpv -----------------------------------------------------------

  function onMpvProperty(name, value) {
    if (name === "pause") paused = value === true
    else if (name === "idle-active") idle = value === true
    else if (name === "playlist-pos") { playlistPos = typeof value === "number" ? value : -1; queueRefresh.restart() }
    else if (name === "playlist-count") { playlistCount = typeof value === "number" ? value : 0; queueRefresh.restart() }
    else if (name === "media-title") mediaTitle = value || ""
    else if (name === "duration") duration = typeof value === "number" ? value : 0
    else if (name === "volume") { if (typeof value === "number") volume = Math.round(value) }
    else if (name === "paused-for-cache") buffering = value === true
    else if (name === "loop-file") _loopFile = value
    else if (name === "loop-playlist") _loopPlaylist = value
    else if (name === "user-data/ytm/stale" && Array.isArray(value) && value.length > 0) {
      // mpv/ytm-streams.lua dropped streams that failed to play.
      dropStreams(value)
      mpv.command(["set_property", "user-data/ytm/stale", []])
    }
  }

  function onMpvEvent(message) {
    if (message.event === "start-file") {
      buffering = true
      position = 0
    } else if (message.event === "file-loaded") {
      buffering = false
      lastError = ""
      consecutiveErrors = 0
      _retryIndex = -1
      _pendingNotice = null
      errorNotice.stop()
    } else if (message.event === "end-file" && message.reason === "error") {
      buffering = false
      // By now mpv may already be loading the next entry, so name the one
      // the event is about.
      var entry = Model.entryById(queue, message.playlist_entry_id)
      var failed = entry ? entry.track : currentTrack
      var title = failed ? "\"" + failed.title + "\"" : "the track"
      if (consecutiveErrors === 0) _retryIndex = entry ? entry.index : playlistPos
      fail("Could not play " + title + ": " + (message.file_error || "unknown error"))
      queueErrorNotice(title, message.file_error || "unknown error")
      // Offline (or yt-dlp broken), every entry fails in ~0.5 s: stop after
      // three instead of running through the whole queue. The queue stays;
      // play/pause continues from the first failure.
      if (consecutiveErrors >= 3) mpv.command(["stop", "keep-playlist"])
    }
  }

  function onMpvReady() {
    applyRepeat()
    mpv.command(["get_property", "user-data/ytm/order"], function(reply) {
      root.shuffleOrder = reply && reply.error === "success" && Array.isArray(reply.data) ? reply.data : []
    })
    // Streams resolved before a plugin reload or shell restart live in mpv.
    mpv.command(["get_property", "user-data/ytm/streams"], function(reply) {
      if (!reply || reply.error !== "success" || !reply.data || typeof reply.data !== "object") {
        root.pushStreams()
        return
      }
      var merged = ({})
      for (var key in reply.data) merged[key] = reply.data[key]
      for (var local in root.streams) merged[local] = root.streams[local]
      root.streams = Model.pruneStreams(merged, root.nowSec(), 50)
      root.pushStreams()
    })
    mpv.command(["get_property", "user-data/ytm/meta"], function(reply) {
      if (reply && reply.error === "success" && reply.data && typeof reply.data === "object") {
        var merged = ({})
        for (var key in reply.data) merged[key] = reply.data[key]
        for (var local in root.meta) merged[local] = root.meta[local]
        root.meta = merged
      }
      root.refreshQueue()
    })
  }

  function refreshQueue() {
    if (!mpv.up) return
    mpv.command(["get_property", "playlist"], function(reply) {
      if (!reply || reply.error !== "success") return
      root.playlist = reply.data || []
      metaSync.restart()
      root.lookUpUnknownTracks()
    })
  }

  // Entries queued by someone else (or before a restart lost the metadata).
  function lookUpUnknownTracks() {
    var ids = Model.unknownVideoIds(queue, 10)
    for (var i = 0; i < ids.length; i++) {
      var videoId = ids[i]
      if (_lookedUp[videoId]) continue
      _lookedUp[videoId] = true
      backend.request("song", { videoId: videoId }, function(reply) {
        if (reply.ok) root.remember([reply.result])
      })
    }
  }

  function pushMeta() {
    if (!mpv.up) return
    mpv.command(["set_property", "user-data/ytm/meta", Model.pruneMeta(meta, playlist)])
  }

  function resetPlayback() {
    paused = false
    idle = true
    buffering = false
    playlistPos = -1
    playlistCount = 0
    mediaTitle = ""
    duration = 0
    position = 0
    playlist = []
    // Entry ids start over in the next player.
    shuffleOrder = []
    _loopFile = false
    _loopPlaylist = false
  }

  function statusJson() {
    return JSON.stringify({
      plugin: pluginId,
      version: version,
      startedAt: startedAt,
      mpv: mpvState,
      worker: workerState,
      missingTools: missingTools,
      auth: authState,
      signedIn: signedIn,
      expiryNotified: expiryNotified,
      like: currentLike,
      libraryPlaylists: storeItem.playlists.length,
      playing: playing,
      paused: paused,
      idle: idle,
      buffering: buffering,
      volume: volume,
      position: position,
      duration: duration,
      current: currentTrack ? { videoId: currentTrack.videoId, title: currentTrack.title, artists: currentTrack.artistText } : null,
      queueIndex: playlistPos,
      queue: queue.map(function(entry) { return entry.videoId }),
      player: {
        autoplay: autoplay,
        autoplayWanted: autoplayWanted,
        autoplaySeed: _autoplaySeed,
        shuffle: shuffle,
        repeat: repeatMode,
        shuffleOrder: shuffleOrder.length
      },
      lastError: lastError,
      streams: {
        fresh: Object.keys(Model.pruneStreams(streams, nowSec(), 50)),
        resolving: resolvingCount,
        pending: pendingTitle,
        speculated: speculated
      },
      cache: {
        thumbs: storeItem.thumbCount,
        searches: storeItem.searchCacheSize
      },
      session: {
        canResume: canResume,
        index: session ? session.index : -1,
        timePos: session ? session.timePos : 0,
        tracks: session ? session.videoIds.length : 0
      },
      search: {
        query: storeItem.query,
        filter: storeItem.filter,
        busy: storeItem.searching,
        ms: storeItem.lastSearchMs,
        rows: Model.flattenSearch(storeItem.result, storeItem.filter).length,
        error: storeItem.searchError,
        inputFocused: storeItem.inputFocused,
        recent: storeItem.recent.length,
        suggestions: storeItem.suggestions.map(function(s) { return s.text })
      }
    })
  }

  // ---- required tools ------------------------------------------------------------
  // Omarchy ships mpv, mpv-mpris and yt-dlp; uv (runs the ytmusicapi helper)
  // and deno (yt-dlp's solver for YouTube's JavaScript challenge) usually have
  // to be added. Checked at start and whenever a panel opens.
  readonly property var requiredTools: ["uv", "mpv", "yt-dlp", "deno"]
  property var missingTools: []
  property var _missingFound: []
  readonly property string installCommand: "omarchy-pkg-add " + missingTools.join(" ")

  function checkTools() {
    if (toolCheck.running) return
    _missingFound = []
    toolCheck.running = true
  }

  function installTools() {
    if (missingTools.length === 0) return false
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", installCommand])
    return true
  }

  Process {
    id: toolCheck
    command: ["sh", "-c",
      "for t in \"$@\"; do command -v \"$t\" >/dev/null 2>&1 || echo \"$t\"; done; "
        + "[ -e /etc/mpv/scripts/mpris.so ] || [ -e /usr/lib/mpv-mpris/mpris.so ] || echo mpv-mpris",
      "sh"].concat(root.requiredTools)
    stdout: SplitParser {
      onRead: data => {
        if (data.trim() !== "") root._missingFound = root._missingFound.concat([data.trim()])
      }
    }
    onExited: root.missingTools = root._missingFound
  }

  function togglePanel() {
    if (!shell || typeof shell.toggle !== "function") return false
    shell.toggle(pluginId)
    return true
  }

  MpvClient {
    id: mpv
    socketPath: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-ytmusic/mpv.sock"
    controlScript: root.rootDir + "/bin/ytm-mpv"
    startVolume: root.volume
    observedProperties: ["pause", "idle-active", "playlist-pos", "playlist-count", "media-title", "duration", "volume", "paused-for-cache", "loop-file", "loop-playlist", "user-data/ytm/stale"]

    onPropertyUpdated: (name, value) => root.onMpvProperty(name, value)
    onEvent: message => root.onMpvEvent(message)
    onReady: root.onMpvReady()
    onMpvStateChanged: if (mpvState === "down") root.resetPlayback()
  }

  Backend {
    id: backend
    launcher: root.rootDir + "/bin/ytm"
  }

  // Search results and opened collections, shared by every panel.
  readonly property var store: storeItem

  Store {
    id: storeItem
    worker: backend
    thumbsEnabled: root.panelsOpen > 0
    stateDir: root.cacheDir
  }

  Connections {
    target: storeItem
    function onTrackHinted(track) { root.speculate(track) }
  }

  FileView {
    id: accountFile
    path: root.configDir + "/account.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.setAccount(text())
    onLoadFailed: root.setAccount("")
    // text() is stale inside the change signal itself, so re-read first.
    onFileChanged: reload()
  }

  Timer {
    id: likeCheck
    interval: 600
    onTriggered: root.refreshLikeStatus()
  }

  FileView {
    id: sessionFile
    path: root.cacheDir + "/session.json"
    atomicWrites: true
    watchChanges: false
    printErrors: false
    onLoaded: root.session = Model.parseSession(text())
    onLoadFailed: root.session = null
  }

  FileView {
    id: prefsFile
    path: root.cacheDir + "/player.json"
    atomicWrites: true
    watchChanges: false
    printErrors: false
    onLoaded: root.applyPrefs(text())
    onLoadFailed: root.applyPrefs("")
  }

  Timer {
    id: sessionSave
    interval: 2000
    onTriggered: root.saveSession()
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.playing
    onTriggered: root.saveSession()
  }

  Timer {
    id: errorNotice
    interval: 4000
    onTriggered: {
      var notice = root._pendingNotice
      root._pendingNotice = null
      if (notice) root.notifyOnce(notice.key, notice.title, notice.body)
    }
  }

  // The session file's directory may not exist before the first save, and it
  // must be private whoever created it first.
  Component.onCompleted: {
    Quickshell.execDetached(["sh", "-c", "mkdir -p \"$1\" && chmod 700 \"$1\"", "sh", root.cacheDir])
    checkTools()
  }

  // Waits a few seconds into the last song, so skipping through the queue
  // doesn't fetch anything.
  Timer {
    id: autoplayTimer
    interval: 5000
    onTriggered: root.refillAutoplay()
  }

  Timer {
    id: queueRefresh
    interval: 50
    onTriggered: root.refreshQueue()
  }

  // Resolve the next track a moment after the current one starts (a fast
  // skip through the queue doesn't resolve every track it passes).
  Timer {
    id: preResolve
    interval: 1500
    onTriggered: root.preResolveUpcoming()
  }

  Timer {
    id: pendingFallback
    // A cold worker (start, first search, loading yt-dlp) can take ~4 s; give
    // up only well after that. A failed resolve falls back right away.
    interval: 10000
    onTriggered: if (root._pendingPlay) root.runPendingPlay(root._pendingPlay.token)
  }

  Timer {
    id: metaSync
    interval: 300
    onTriggered: root.pushMeta()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.positionWanted && root.playing
    onTriggered: root.fetchPosition()
  }

  // On a hot reload the shell creates this instance before the previous one
  // is actually deleted (destroy() is deferred), and Quickshell ignores a
  // second handler for a target that is still taken. Registering a moment
  // later lets the fresh instance own "ytmusic" after every reload.
  property bool ipcReady: false

  Timer {
    interval: 250
    running: true
    onTriggered: root.ipcReady = true
  }

  IpcHandler {
    enabled: root.ipcReady
    target: "ytmusic"

    function ping(): string { return "ok" }
    function status(): string { return root.statusJson() }
    function toggle(): string { return root.togglePanel() ? "ok" : "unavailable" }
    function playPause(): string { return root.playPause() ? "ok" : "unhandled" }
    function next(): string { return root.next() ? "ok" : "unhandled" }
    function previous(): string { return root.previous() ? "ok" : "unhandled" }
    function stop(): string { return root.stop() ? "ok" : "unhandled" }
    function resume(): string { return root.resume() ? "ok" : "unhandled" }
    function seek(seconds: real): string { return root.seek(seconds) ? "ok" : "unhandled" }
    function volume(percent: int): string { return root.setVolume(percent) ? "ok" : "unhandled" }
    function play(query: string): string { return root.playQuery(query, "now") ? "ok" : "unhandled" }
    function playNext(query: string): string { return root.playQuery(query, "next") ? "ok" : "unhandled" }
    function queue(query: string): string { return root.playQuery(query, "queue") ? "ok" : "unhandled" }
    function shuffle(): string { return root.toggleShuffle() ? (root.shuffle ? "on" : "off") : "busy" }
    function repeat(): string { root.cycleRepeat(); return root.repeatPref }
    function autoplay(): string { root.toggleAutoplay(); return root.autoplay ? "on" : "off" }
    function search(query: string): string { return root.showSearch(query) ? "ok" : "unhandled" }
    function like(): string { return root.setLike(root.currentTrack, true) ? "ok" : "unhandled" }
    function unlike(): string { return root.setLike(root.currentTrack, false) ? "ok" : "unhandled" }
    function toggleLike(): string { return root.toggleLike(root.currentTrack) ? "ok" : "unhandled" }
    function reloadAuth(): string { return root.reloadAuth() ? "ok" : "unhandled" }
    function signIn(): string { return root.signIn() ? "ok" : "unhandled" }
    function signOut(): string { return root.signOut() ? "ok" : "unhandled" }
  }
}
