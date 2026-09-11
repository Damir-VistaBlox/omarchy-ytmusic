-- Quit the player once it has had nothing loaded, or has been paused, for too
-- long, so it never lingers in memory after the music stops. Lives inside mpv
-- so it works even if the shell is gone.
local options = { idle_secs = 300, pause_secs = 1800 }
require("mp.options").read_options(options, "ytm-idle")

local timer = nil

local function disarm()
  if timer then
    timer:kill()
    timer = nil
  end
end

local function arm(seconds)
  disarm()
  timer = mp.add_timeout(seconds, function() mp.command("quit") end)
end

local function update()
  if mp.get_property_bool("idle-active") then
    arm(options.idle_secs)
  elseif mp.get_property_bool("pause") then
    arm(options.pause_secs)
  else
    disarm()
  end
end

mp.observe_property("idle-active", "bool", update)
mp.observe_property("pause", "bool", update)
