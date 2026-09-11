const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../YtmModel.js")

const track = (id, extra = {}) => ({ videoId: id, title: "Song " + id, artistText: "Artist", available: true, ...extra })
const id11 = n => ("vid" + n).padEnd(11, "x")

test("track urls round-trip through videoIdFromUrl", () => {
  const id = "4D7u5KF7SP8"
  assert.equal(Model.trackUrl(id), "https://www.youtube.com/watch?v=4D7u5KF7SP8")
  assert.equal(Model.videoIdFromUrl(Model.trackUrl(id)), id)
  assert.equal(Model.videoIdFromUrl("https://music.youtube.com/watch?v=" + id + "&list=RD"), id)
  assert.equal(Model.videoIdFromUrl("https://youtu.be/" + id), id)
  assert.equal(Model.videoIdFromUrl("/tmp/file.opus"), "")
  assert.equal(Model.videoIdFromUrl(undefined), "")
})

test("media title and loadfile options use byte-length quoting", () => {
  assert.equal(Model.mediaTitle({ title: "Get Lucky", artistText: "Daft Punk" }), "Get Lucky — Daft Punk")
  assert.equal(Model.mediaTitle({ title: "Solo" }), "Solo")
  assert.equal(Model.utf8Length("a—é😀"), 1 + 3 + 2 + 4)
  const title = "Hello, World — A=B"
  assert.equal(Model.loadfileOptions({ title: "Hello, World", artistText: "A=B" }),
    `force-media-title=%${Buffer.byteLength(title)}%${title}`)
  assert.equal(Model.loadfileOptions({}), "")
})

test("play now depends on the queue state", () => {
  const t = track(id11(1))
  const url = Model.trackUrl(t.videoId)
  assert.deepEqual(Model.playNowCommands(t, { count: 0, pos: -1 }).map(c => c.slice(0, 3)),
    [["loadfile", url, "replace"], ["set_property", "pause", false]])
  assert.deepEqual(Model.playNowCommands(t, { count: 3, pos: -1 }).slice(0, 2).map(c => c.slice(0, 3)),
    [["loadfile", url, "append"], ["playlist-play-index", 3]])
  assert.deepEqual(Model.playNowCommands(t, { count: 3, pos: 1 }).slice(0, 2).map(c => c.slice(0, 3)),
    [["loadfile", url, "insert-next"], ["playlist-play-index", 2]])
  const [cmd] = Model.playNowCommands(t, { count: 0, pos: -1 })
  assert.equal(cmd[3], -1, "index argument precedes options since mpv 0.38")
  assert.match(cmd[4], /^force-media-title=%\d+%Song/)
})

test("play next and add to queue", () => {
  const t = track(id11(2))
  assert.equal(Model.playNextCommands(t)[0][2], "insert-next-play")
  assert.equal(Model.addToQueueCommands(t)[0][2], "append-play")
})

test("play collection replaces the queue and skips unavailable tracks", () => {
  const tracks = [track(id11(1)), track(id11(2), { available: false }), track(id11(3)), { title: "no id" }]
  const plan = Model.playCollectionCommands(tracks, 1, false)
  assert.deepEqual(plan.tracks.map(t => t.videoId), [id11(1), id11(3)])
  assert.deepEqual(plan.commands[0], ["stop"])
  assert.deepEqual(plan.commands.slice(1, 3).map(c => c[2]), ["append", "append"])
  assert.deepEqual(plan.commands.slice(-2), [["playlist-play-index", 1], ["set_property", "pause", false]])
  assert.deepEqual(Model.playCollectionCommands([], 0, false), { commands: [], tracks: [], originalIndex: [], index: -1 })
  assert.equal(Model.playCollectionCommands(tracks, 99, false).commands.at(-2)[1], 1, "start index is clamped")
  const later = Model.playCollectionCommands([track(id11(1), { available: false }), track(id11(2)), track(id11(3))], 2, false)
  assert.equal(later.tracks[later.index].videoId, id11(3), "start indexes the collection, not the playable subset")
})

test("shuffle mode keeps the clicked song first and remembers the original order", () => {
  const tracks = Array.from({ length: 12 }, (_, i) => track(id11(i)))
  const plan = Model.playCollectionCommands(tracks, 4, true, 7, true)
  assert.equal(plan.index, 0)
  assert.equal(plan.tracks[0].videoId, id11(4))
  assert.deepEqual([...plan.originalIndex].sort((a, b) => a - b), tracks.map((_, i) => i))
  plan.tracks.forEach((t, k) => assert.equal(t, tracks[plan.originalIndex[k]]))
  // mpv entry ids as loaded, listed back in the collection's order
  const entryIds = plan.tracks.map((_, k) => 100 + k)
  const order = Model.originalOrder(entryIds, plan.originalIndex)
  assert.deepEqual(order.map(id => plan.tracks[id - 100].videoId), tracks.map(t => t.videoId))
})

test("repeat modes map to mpv's loop properties", () => {
  assert.deepEqual(["off", "all", "one"].map(Model.nextRepeat), ["all", "one", "off"])
  assert.equal(Model.nextRepeat("bogus"), "all")
  assert.equal(Model.repeatMode(false, false), "off")
  assert.equal(Model.repeatMode(false, "inf"), "all")
  assert.equal(Model.repeatMode("inf", "inf"), "one")
  assert.equal(Model.repeatMode(false, 3), "all")
  assert.deepEqual(Model.repeatCommands("one"), [["set_property", "loop-file", "inf"], ["set_property", "loop-playlist", "no"]])
  assert.deepEqual(Model.repeatCommands("all"), [["set_property", "loop-file", "no"], ["set_property", "loop-playlist", "inf"]])
  assert.deepEqual(Model.repeatCommands("x"), [["set_property", "loop-file", "no"], ["set_property", "loop-playlist", "no"]])
})

test("shuffle reorders only upcoming entries and unshuffle restores them", () => {
  // mpv semantics (spike S7): moving an entry up puts it exactly at the target index.
  const apply = (list, commands) => commands.reduce((out, [, from, to]) => {
    assert.ok(from > to, "reorderCommands only moves entries up")
    const next = out.slice()
    const [item] = next.splice(from, 1)
    next.splice(to, 0, item)
    return next
  }, list)
  const ids = [1, 2, 3, 4, 5, 6, 7, 8]
  const shuffledIds = Model.shuffleOrder(ids, 2, 99)
  assert.deepEqual(shuffledIds.slice(0, 3), [1, 2, 3], "played entries and the current one stay")
  assert.deepEqual([...shuffledIds].sort((a, b) => a - b), ids)
  assert.deepEqual(apply(ids, Model.reorderCommands(ids, shuffledIds)), shuffledIds)
  // "play next" inserted 9 after the current entry, "add to queue" appended 10
  const later = [shuffledIds[0], shuffledIds[1], shuffledIds[2], 9, ...shuffledIds.slice(3), 10]
  const restored = Model.unshuffleOrder(later, ids)
  assert.deepEqual(restored, [1, 2, 3, 9, 4, 5, 6, 7, 8, 10])
  assert.deepEqual(apply(later, Model.reorderCommands(later, restored)), restored)
  assert.deepEqual(Model.unshuffleOrder([3, 1, 2], []), [3, 1, 2], "nothing recorded: order kept")
  for (let seed = 0; seed < 20; seed++) {
    const target = Model.shuffleOrder(ids, -1, seed)
    assert.deepEqual(apply(ids, Model.reorderCommands(ids, target)), target)
  }
})

test("autoplay picks skip queued songs and prefer songs over videos", () => {
  const queue = Model.buildQueue([{ filename: Model.trackUrl(id11(1)) }, { filename: Model.trackUrl(id11(2)) }], {})
  const picks = Model.autoplayPicks(queue, [
    track(id11(2)), track(id11(3), { kind: "video" }), track(id11(4)), track(id11(4)),
    track(id11(5), { available: false }), track(id11(6)), { title: "no id" }], 3)
  assert.deepEqual(picks.map(t => t.videoId), [id11(4), id11(6), id11(3)])
  assert.deepEqual(Model.autoplayPicks(queue, [], 5), [])
})

test("player preferences parse with defaults", () => {
  assert.deepEqual(Model.parsePrefs(""), { autoplay: true, shuffle: false, repeat: "off" })
  assert.deepEqual(Model.parsePrefs('{"autoplay":false,"shuffle":true,"repeat":"one"}'), { autoplay: false, shuffle: true, repeat: "one" })
  assert.deepEqual(Model.parsePrefs('{"autoplay":"yes","repeat":"sometimes"}'), { autoplay: true, shuffle: false, repeat: "off" })
})

test("shuffled play is a seeded permutation starting at index 0", () => {
  const tracks = Array.from({ length: 20 }, (_, i) => track(id11(i)))
  const a = Model.playCollectionCommands(tracks, 5, true, 42)
  const b = Model.playCollectionCommands(tracks, 5, true, 42)
  assert.deepEqual(a.tracks, b.tracks, "same seed, same order")
  assert.notDeepEqual(a.tracks.map(t => t.videoId), tracks.map(t => t.videoId))
  assert.deepEqual([...a.tracks].map(t => t.videoId).sort(), tracks.map(t => t.videoId).sort())
  assert.deepEqual(a.commands.at(-2), ["playlist-play-index", 0])
})

test("moveArgs matches mpv's insert-before semantics (spike S7)", () => {
  // Observed: playlist-move 3 1 put entry 3 at index 1; playlist-move 1 3 put entry 1 at index 2.
  assert.deepEqual(Model.moveArgs(3, 1), ["playlist-move", 3, 1])
  assert.deepEqual(Model.moveArgs(1, 2), ["playlist-move", 1, 3])
  const simulate = (list, [, from, to]) => {
    const out = list.slice()
    const [item] = out.splice(from, 1)
    out.splice(to > from ? to - 1 : to, 0, item)
    return out
  }
  const list = ["a", "b", "c", "d"]
  for (let from = 0; from < 4; from++)
    for (let to = 0; to < 4; to++) {
      if (from === to) continue
      assert.equal(simulate(list, Model.moveArgs(from, to))[to], list[from], `move ${from}->${to}`)
    }
})

test("previous restarts the track after 5 seconds", () => {
  assert.deepEqual(Model.previousCommands(12.5), [["seek", 0, "absolute"]])
  assert.deepEqual(Model.previousCommands(2), [["playlist-prev", "weak"]])
  assert.deepEqual(Model.previousCommands(undefined), [["playlist-prev", "weak"]])
})

test("buildQueue joins mpv's playlist with metadata", () => {
  const known = track(id11(1), { artistText: "Daft Punk" })
  const playlist = [
    { filename: Model.trackUrl(id11(1)), current: true, playing: true, id: 5 },
    { filename: Model.trackUrl(id11(2)), id: 6, title: "From mpv" },
  ]
  const queue = Model.buildQueue(playlist, { [id11(1)]: known })
  assert.equal(queue.length, 2)
  assert.deepEqual([queue[0].index, queue[0].entryId, queue[0].current, queue[0].known], [0, 5, true, true])
  assert.equal(queue[0].track, known)
  assert.equal(queue[1].known, false)
  assert.equal(queue[1].track.title, "From mpv")
  assert.equal(queue[1].track.videoId, id11(2))
  assert.deepEqual(Model.unknownVideoIds(queue), [id11(2)])
  assert.deepEqual(Model.buildQueue(null, null), [])
})

test("failed tracks are found by entry id and notices escalate", () => {
  const queue = Model.buildQueue([{ filename: Model.trackUrl(id11(1)), id: 7 }, { filename: Model.trackUrl(id11(2)), id: 8 }],
    { [id11(1)]: track(id11(1)), [id11(2)]: track(id11(2)) })
  assert.equal(Model.entryById(queue, 8).track.videoId, id11(2))
  assert.equal(Model.entryById(queue, 8).index, 1)
  assert.equal(Model.entryById(queue, 99), null)
  assert.equal(Model.entryById(queue, undefined), null)
  assert.deepEqual(Model.playbackNotice(1, '"A"', "loading failed", false), { key: 'play-error:"A"', title: 'Couldn\'t play "A"', body: "loading failed" })
  assert.equal(Model.playbackNotice(2, '"A"', "x", true).key, 'play-error:"A"', "one or two failures: just that track")
  assert.equal(Model.playbackNotice(3, '"A"', "x", false).key, "errors-in-a-row")
  assert.equal(Model.playbackNotice(4, '"A"', "x", true).key, "offline")
  assert.match(Model.playbackNotice(3, '"A"', "x", true).body, /connection/)
})

test("pruneMeta keeps only queued tracks", () => {
  const meta = { [id11(1)]: track(id11(1)), [id11(9)]: track(id11(9)) }
  assert.deepEqual(Object.keys(Model.pruneMeta(meta, [{ filename: Model.trackUrl(id11(1)) }])), [id11(1)])
})

test("formatDuration", () => {
  assert.equal(Model.formatDuration(0), "0:00")
  assert.equal(Model.formatDuration(354), "5:54")
  assert.equal(Model.formatDuration(3723), "1:02:03")
  assert.equal(Model.formatDuration(null), "0:00")
  assert.equal(Model.formatDuration(-1), "")
  assert.equal(Model.formatDuration(NaN), "")
})

test("queue all appends and starts playback with the first track", () => {
  const plan = Model.queueAllCommands([track(id11(1)), track(id11(2), { available: false }), track(id11(3))])
  assert.deepEqual(plan.tracks.map(t => t.videoId), [id11(1), id11(3)])
  assert.deepEqual(plan.commands.map(c => c[2]), ["append-play", "append"])
  assert.deepEqual(Model.queueAllCommands([]).commands, [])
})

test("flattenSearch groups results under headers", () => {
  const song = { type: "track", videoId: id11(1) }
  const album = { type: "album", browseId: "MPREb_1" }
  const rows = Model.flattenSearch({ top: [album], songs: [song], albums: [], artists: [], playlists: [], videos: [] })
  assert.deepEqual(rows.map(r => r.header ? "# " + r.title : r.item.type), ["# Top result", "album", "# Songs", "track"])
  const filtered = Model.flattenSearch({ items: [song, song] }, "songs")
  assert.deepEqual(filtered.map(r => r.header ? "#" : "i"), ["#", "i", "i"])
  assert.deepEqual(Model.flattenSearch(null), [])
  assert.deepEqual(Model.flattenSearch({ items: [] }, "albums"), [])
})

test("artist pages and track rows carry the index a click plays from", () => {
  const songs = [track(id11(1)), track(id11(2))]
  const rows = Model.flattenArtist({ songs, albums: [{ type: "album" }], singles: [] })
  assert.deepEqual(rows.map(r => r.header ? r.title : r.trackIndex), ["Top songs", 0, 1, "Albums", undefined])
  assert.deepEqual(Model.trackRows(songs).map(r => r.trackIndex), [0, 1])
  assert.deepEqual(Model.flattenArtist(null), [])
})

test("firstTrack finds the first playable track row", () => {
  const rows = Model.flattenSearch({
    top: [{ type: "artist", name: "Daft Punk" }],
    songs: [track(id11(1), { type: "track", available: false }), track(id11(2), { type: "track" })]
  }, "")
  assert.equal(Model.firstTrack(rows).videoId, id11(2))
  assert.equal(Model.firstTrack([{ header: true, title: "x" }]), null)
  assert.equal(Model.firstTrack(null), null)
})

test("nextSelectable skips headers and stays at the ends", () => {
  const rows = [{ header: true }, { item: 1 }, { item: 2 }, { header: true }, { item: 3 }]
  assert.equal(Model.nextSelectable(rows, -1, 1), 1)
  assert.equal(Model.nextSelectable(rows, 2, 1), 4)
  assert.equal(Model.nextSelectable(rows, 4, 1), 4)
  assert.equal(Model.nextSelectable(rows, 4, -1), 2)
  assert.equal(Model.nextSelectable(rows, 1, -1), 1)
  assert.equal(Model.nextSelectable(rows, -1, -1), 4)
  assert.equal(Model.nextSelectable([], -1, 1), -1)
})

test("item subtitles and collection targets", () => {
  assert.equal(Model.itemSubtitle({ type: "album", albumType: "Album", artistText: "Daft Punk", year: "2013" }), "Album • Daft Punk • 2013")
  assert.equal(Model.itemSubtitle({ type: "playlist", author: "Me", count: 12 }), "Me • 12 songs")
  assert.equal(Model.itemSubtitle({ type: "track", artistText: "A", kind: "video" }), "A • Video")
  assert.equal(Model.itemSubtitle({ type: "artist" }), "Artist")
  assert.deepEqual(Model.collectionTarget({ type: "album", browseId: "B" }), { kind: "album", id: "B" })
  assert.deepEqual(Model.collectionTarget({ type: "artist", channelId: "UC" }), { kind: "artist", id: "UC" })
  assert.equal(Model.collectionTarget({ type: "track" }), null)
})

test("library rows: liked first, then own and saved playlists", () => {
  const playlists = [
    { playlistId: "LM", title: "Liked Music", owned: true },
    { playlistId: "SE", title: "Episodes", owned: true },
    { playlistId: "PL1", title: "Mine", owned: true },
    { playlistId: "PL2", title: "Theirs", owned: false },
  ]
  const rows = Model.libraryRows(playlists)
  assert.deepEqual(rows.map(r => r.header ? "# " + r.title : r.item.title),
    ["Liked Music", "History", "# Your playlists", "Mine", "# Saved playlists", "Theirs"])
  assert.equal(rows[0].item.type, "liked")
  assert.equal(rows[1].item.type, "history")
  assert.deepEqual(Model.ownedPlaylists(playlists).map(p => p.playlistId), ["PL1"])
  assert.equal(Model.itemSubtitle({ type: "liked" }), "Songs you liked")
  assert.equal(Model.itemSubtitle({ type: "history" }), "Recently played")
  assert.deepEqual(Model.collectionTarget({ type: "history" }), { kind: "history", id: "history" })
  assert.deepEqual(Model.libraryRows([]).length, 2)
})

test("home rows: shelves as headers, tracks indexed within their shelf", () => {
  const shelves = [
    { title: "Quick picks", items: [{ type: "track", videoId: "a" }, { type: "album" }, { type: "track", videoId: "b" }] },
    { title: "Empty", items: [] },
    { title: "Mixes", items: [{ type: "playlist" }] },
  ]
  const rows = Model.homeRows(shelves)
  assert.deepEqual(rows.map(r => r.header ? "# " + r.title : r.item.type + (r.trackIndex !== undefined ? r.trackIndex : "")),
    ["# Quick picks", "track0", "album", "track1", "# Mixes", "playlist"])
  assert.equal(rows[3].shelfIndex, 0)
  assert.deepEqual(Model.shelfTracks(shelves, 0).map(t => t.videoId), ["a", "b"])
  assert.deepEqual(Model.shelfTracks(shelves, 9), [])
})

test("history rows group by played label", () => {
  const rows = Model.historyRows([{ videoId: "a", played: "Today" }, { videoId: "b", played: "Today" },
    { videoId: "c", played: "Yesterday" }, { videoId: "d" }])
  assert.deepEqual(rows.map(r => r.header ? "# " + r.title : r.trackIndex),
    ["# Today", 0, 1, "# Yesterday", 2, "# Earlier", 3])
})

test("session snapshot round-trips into resume commands", () => {
  const known = track(id11(1))
  const queue = [
    { videoId: id11(1), known: true, track: known },
    { videoId: id11(2), known: false, track: { title: "?" } },
    { videoId: "", known: false, track: {} },
  ]
  const snap = Model.sessionSnapshot(queue, 1, 93.7, 80, 5)
  assert.deepEqual(snap, { version: 1, savedAt: 5, index: 1, timePos: 93, volume: 80,
    videoIds: [id11(1), id11(2)], meta: { [id11(1)]: known } })
  assert.deepEqual(Model.parseSession(JSON.stringify(snap)), snap)
  assert.equal(Model.parseSession("{}"), null)
  assert.equal(Model.parseSession("garbage"), null)
  const plan = Model.resumeCommands(snap)
  assert.equal(plan.index, 1)
  assert.deepEqual(plan.commands[0], ["stop"])
  assert.equal(plan.commands[1][4].endsWith("start=93"), false, "only the current track seeks")
  assert.match(plan.commands[2][4], /start=93$/)
  assert.deepEqual(plan.commands.slice(-2), [["playlist-play-index", 1], ["set_property", "pause", false]])
  assert.equal(plan.tracks[1].videoId, id11(2), "unknown tracks get a placeholder")
  assert.deepEqual(Model.resumeCommands(null).commands, [])
})

test("withoutTrack removes one entry, preferring setVideoId", () => {
  const page = { title: "P", trackCount: 3, tracks: [
    { videoId: "a", setVideoId: "S1" }, { videoId: "a", setVideoId: "S2" }, { videoId: "b", setVideoId: "S3" }] }
  const next = Model.withoutTrack(page, { videoId: "a", setVideoId: "S2" })
  assert.deepEqual(next.tracks.map(t => t.setVideoId), ["S1", "S3"])
  assert.equal(next.trackCount, 2)
  assert.equal(page.tracks.length, 3, "original untouched")
  const liked = Model.withoutTrack({ trackCount: 1, tracks: [{ videoId: "a" }] }, { videoId: "a" })
  assert.deepEqual(liked.tracks, [])
  assert.equal(Model.withoutTrack(null, {}), null)
})

test("stream freshness, pruning and what to resolve next", () => {
  const now = 1000
  assert.equal(Model.streamFresh({ url: "u", expires: now + 600 }, now), true)
  assert.equal(Model.streamFresh({ url: "u", expires: now + 60 }, now), false, "inside the 2 min margin")
  assert.equal(Model.streamFresh({ expires: now + 600 }, now), false)
  assert.equal(Model.streamFresh(null, now), false)
  const streams = { a: { url: "u", expires: now + 900 }, b: { url: "u", expires: now + 10 }, c: { url: "u", expires: now + 5000 } }
  assert.deepEqual(Object.keys(Model.pruneStreams(streams, now, 50)).sort(), ["a", "c"])
  assert.deepEqual(Object.keys(Model.pruneStreams(streams, now, 1)), ["c"])
  const queue = ["a", "b", "c", "d"].map(videoId => ({ videoId }))
  assert.deepEqual(Model.streamsToResolve(queue, 0, streams, now), ["b"], "b is stale")
  assert.deepEqual(Model.streamsToResolve(queue, 1, streams, now), [], "c is fresh")
  assert.deepEqual(Model.streamsToResolve(queue, 1, streams, now, 2), ["d"])
  assert.deepEqual(Model.streamsToResolve(queue, 3, streams, now), [], "nothing after the last entry")
  assert.deepEqual(Model.streamsToResolve(queue, -1, streams, now), [])
})

test("recent searches: newest first, no duplicates, bounded, parsed safely", () => {
  let list = []
  for (const q of ["daft punk", "nils frahm", "  Daft Punk ", "", "air"]) list = Model.rememberQuery(list, q, 3)
  assert.deepEqual(list, ["air", "Daft Punk", "nils frahm"])
  assert.deepEqual(Model.rememberQuery(list, "boards", 3), ["boards", "air", "Daft Punk"])
  assert.deepEqual(Model.forgetQuery(list, "daft punk"), ["air", "nils frahm"])
  assert.deepEqual(Model.parseRecent('{"version":1,"queries":["a"," ",3,"b"]}'), ["a", "b"])
  assert.deepEqual(Model.parseRecent("nope"), [])
  const rows = Model.recentRows(list, 2)
  assert.deepEqual(rows[0], { header: true, title: "Recent searches" })
  assert.deepEqual(rows.slice(1).map(r => [r.item.type, r.item.text, r.item.removable]), [["query", "air", true], ["query", "Daft Punk", true]])
  assert.deepEqual(Model.recentRows([], 8), [])
})

test("suggestions: two matching recent searches, then YouTube's, never the typed text", () => {
  const recent = ["daft punk get lucky", "daft punk live", "daft punk tron", "air"]
  const remote = [{ text: "daft punk" }, { text: "Daft Punk Get Lucky" }, { text: "daft punk one more time", fromHistory: true }, { text: "daft punk da funk" }]
  const list = Model.suggestionList(recent, remote, "Daft Punk", 4)
  assert.deepEqual(list, [
    { text: "daft punk get lucky", recent: true },
    { text: "daft punk live", recent: true },
    { text: "daft punk one more time", recent: true },
    { text: "daft punk da funk", recent: false }
  ])
  const rows = Model.suggestionRows(list, 1)
  assert.equal(rows[0].title, "Suggestions")
  assert.deepEqual(rows.slice(1).map(r => r.item.selected), [false, true, false, false])
  assert.ok(rows.slice(1).every(r => r.item.type === "query" && r.item.removable === false))
  assert.deepEqual(Model.suggestionRows([], -1), [])
})

test("search keys ignore case and spacing, keep the filter", () => {
  assert.equal(Model.searchKey("  Daft Punk ", ""), "|daft punk")
  assert.equal(Model.searchKey("daft punk", "songs"), "songs|daft punk")
  assert.notEqual(Model.searchKey("x", "songs"), Model.searchKey("x", "albums"))
})

test("collectThumbs walks results and deduplicates", () => {
  const a = "https://lh3.googleusercontent.com/a", b = "https://i.ytimg.com/b.jpg"
  const result = { thumb: a, thumbLarge: a, tracks: [{ thumb: b, album: { thumb: null } }, { thumb: b }], other: { photo: a } }
  assert.deepEqual(Model.collectThumbs(result), [a, b])
  assert.deepEqual(Model.collectThumbs([{ thumb: "http://insecure/x" }, { thumb: 5 }]), [])
  const many = Array.from({ length: 10 }, (_, i) => ({ thumb: "https://i.ytimg.com/" + i }))
  assert.equal(Model.collectThumbs(many, 3).length, 3)
  assert.deepEqual(Model.collectThumbs(null), [])
})

test("display modes and click mapping", () => {
  assert.equal(Model.normalizeDisplay("player"), "player")
  assert.equal(Model.normalizeDisplay("MINI"), "player")
  assert.equal(Model.normalizeDisplay(undefined), "icon")
  assert.equal(Model.normalizeDisplay("whatever"), "icon")
  assert.equal(Model.nextDisplay("icon"), "player")
  assert.equal(Model.nextDisplay("player"), "icon")
  assert.equal(Model.clickAction(1), "panel")
  assert.equal(Model.clickAction(4), "playPause")
  assert.equal(Model.clickAction(2), "toggleDisplay")
})

test("now playing label", () => {
  assert.equal(Model.nowPlayingLabel({ title: "Says", artistText: "Nils Frahm" }), "Says  ·  Nils Frahm")
  assert.equal(Model.nowPlayingLabel({ title: "Solo" }), "Solo")
  assert.equal(Model.nowPlayingLabel(null), "")
})

test("parseMpvLine", () => {
  assert.deepEqual(Model.parseMpvLine('{"event":"idle"}'), { event: "idle" })
  assert.equal(Model.parseMpvLine("garbage"), null)
  assert.equal(Model.parseMpvLine("42"), null)
})
