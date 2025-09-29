-- @provides
--   [main] Meat-Script_Toggle_ShowOnly_SelectedTracks_in_Mixer.lua
-- @description Toggle: Show Only Selected Tracks in Mixer
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Toggle: Show Only Selected Tracks in Mixer
--   Continuously shows *only* selected tracks in the Mixer (MCP).
--   If no tracks are selected, it shows all tracks.
--   Recommended to add to a custom toolbar via toolbar docker.
--   -> When disabling, select 'Terminate instances' and 'Remember my answer for this script'
--   -> Toggle once to enable (toolbar button lights up), toggle again to disable (restores all visible).

local r = reaper
local NS   = "Meat_ShowOnlySelected_InMixer"   -- ExtState namespace
local KEY_RUNNING = "running"
local KEY_STOP    = "stop"
local KEY_TOKEN   = "token"

-- ---- Toolbar setup
local _, _, sectionID, cmdID = r.get_action_context()
local function set_toggle(on)
  r.SetToggleCommandState(sectionID, cmdID, on and 1 or 0)
  r.RefreshToolbar2(sectionID, cmdID)
end

-- ---- Mixer ops
local function mixer_show_all()
  local n = r.CountTracks(0)
  for i = 0, n-1 do
    local tr = r.GetTrack(0, i)
    r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 1)
  end
end

local function mixer_show_selected_only()
  local n    = r.CountTracks(0)
  local selN = r.CountSelectedTracks(0)

  if selN == 0 then
    mixer_show_all()
    return
  end

  for i = 0, n-1 do
    local tr = r.GetTrack(0, i)
    r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", r.IsTrackSelected(tr) and 1 or 0)
  end
end

-- ---- Selection signature
local function selection_signature()
  local selN = r.CountSelectedTracks(0)
  if selN == 0 then return "NONE" end
  local ids = {}
  for i = 0, selN-1 do
    ids[#ids+1] = r.GetTrackGUID(r.GetSelectedTrack(0, i))
  end
  table.sort(ids)
  return table.concat(ids, "|")
end

-- ---- Singleton / kill-switch guards
local function get(key) return r.GetExtState(NS, key) end
local function set(key, val) r.SetExtState(NS, key, tostring(val or ""), false) end

-- If another instance is running, request it to stop and exit this instance.
if get(KEY_RUNNING) == "1" then
  set(KEY_STOP, "1")
  -- Also bump token so any stubborn old loop sees mismatch and exits
  set(KEY_TOKEN, tostring(math.random()) .. os.clock())
  set_toggle(false)  -- reflect OFF immediately
  return
end

-- Mark this as the sole running instance.
local MY_TOKEN = tostring(math.random()) .. os.clock()
set(KEY_TOKEN, MY_TOKEN)
set(KEY_STOP,  "0")
set(KEY_RUNNING, "1")

-- ---- Main loop
local running = true
local last_sig = ""

local function stop_and_restore()
  if not running then return end
  running = false
  mixer_show_all()
  r.TrackList_AdjustWindows(false)
  set_toggle(false)
  set(KEY_RUNNING, "0")
  set(KEY_STOP,  "0")
end

local function apply_if_needed()
  -- Observe kill requests or token change (newer instance started)
  if get(KEY_STOP) == "1" or get(KEY_TOKEN) ~= MY_TOKEN then
    stop_and_restore()
    return
  end

  local sig = selection_signature()
  if sig ~= last_sig then
    mixer_show_selected_only()
    r.TrackList_AdjustWindows(false)
    last_sig = sig
  end
end

local function loop()
  if not running then return end
  apply_if_needed()
  r.defer(loop)
end

-- Ensure restore on script termination (Close/Stop/Crash path)
r.atexit(stop_and_restore)

-- Start
set_toggle(true)
loop()
