-- Play stream URLs the shell resolved ahead of time (user-data/ytm/streams:
-- videoId -> { url, expires }) instead of running yt-dlp when a track loads:
-- ~0.3 s to audio instead of ~2 s. The playlist keeps the youtube.com URL, so
-- `path`, cover art over MPRIS and the shell's videoId mapping stay intact.
--
-- A pre-resolved URL can go bad (expired after a suspend, network changed).
-- Restoring the youtube.com URL in on_load_fail is too late for mpv's ytdl
-- hook, so the stream is dropped, reported in user-data/ytm/stale for the
-- shell, and the same entry is loaded once more, this time through yt-dlp.
local redirected = {} -- stream URL -> videoId
local retried = {}    -- videoId -> true: each gets one retry
-- { pos, entry }: the entry whose stream just failed. Only that entry's own
-- end-file may use it; anything else (the shell stopped playback, you skipped)
-- drops it, or a later, unrelated failure would restart an old position.
local retry = nil

local function video_id(url)
  return url and url:match("[?&]v=([%w_%-]+)")
end

local function streams()
  local all = mp.get_property_native("user-data/ytm/streams")
  return type(all) == "table" and all or {}
end

local function mark_stale(id)
  local all = streams()
  all[id] = nil
  mp.set_property_native("user-data/ytm/streams", all)
  local stale = mp.get_property_native("user-data/ytm/stale")
  if type(stale) ~= "table" then stale = {} end
  stale[#stale + 1] = id
  mp.set_property_native("user-data/ytm/stale", stale)
end

mp.add_hook("on_load", 5, function()
  local url = mp.get_property("stream-open-filename", "")
  local id = video_id(url)
  if not id then return end
  local stream = streams()[id]
  if type(stream) ~= "table" or type(stream.url) ~= "string" then return end
  if (tonumber(stream.expires) or 0) < os.time() + 60 then return end
  redirected[stream.url] = id
  mp.set_property("stream-open-filename", stream.url)
end)

mp.add_hook("on_load_fail", 5, function()
  local url = mp.get_property("stream-open-filename", "")
  local id = redirected[url]
  if not id then return end
  redirected[url] = nil
  mp.msg.warn("pre-resolved stream for " .. id .. " failed; loading it through yt-dlp")
  mark_stale(id)
  if not retried[id] then
    retried[id] = true
    local pos = mp.get_property_number("playlist-playing-pos")
    if pos and pos >= 0 then
      retry = { pos = pos, entry = mp.get_property_number("playlist/" .. pos .. "/id") }
    end
  end
end)

mp.register_event("end-file", function(event)
  local pending = retry
  retry = nil
  if not pending or event.reason ~= "error" or event.playlist_entry_id ~= pending.entry then return end
  mp.commandv("playlist-play-index", tostring(pending.pos))
end)
