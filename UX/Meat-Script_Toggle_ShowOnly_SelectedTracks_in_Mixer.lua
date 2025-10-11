-- @provides
--   [main] Meat-Script_Toggle_ShowOnly_SelectedTracks_in_Mixer.lua
-- @description Toggle: Show Only Selected Tracks in Mixer
-- @version 1.1
-- @author Jeremy Romberg
-- @about
--   ### Toggle: Show Only Selected Tracks in Mixer
--   Continuously shows selected tracks and any of its parent tracks in the Mixer (MCP).
--   While enabled, if no tracks are selected it shows all tracks.
--   Set 'restore_on_disable' flag to 'true' to restore visibility of all tracks when script is disabled.
--   Recommended to add to a custom toolbar via toolbar docker.
--   -> When disabling, select 'Terminate instances' and 'Remember my answer for this script'
--   -> Toggle once to enable (toolbar button lights up), toggle again to disable (restores all visible).
-- @changelog
--   - Also show any parent tracks of selected tracks.

local r = reaper
local NS          = "Meat_ShowOnlySelected_InMixer"
local KEY_RUNNING = "running"
local KEY_STOP    = "stop"
local KEY_TOKEN   = "token"
local restore_on_disable = false

-- Toolbar toggle state
local _, _, sectionID, cmdID = r.get_action_context()
local function set_toggle(on)
  r.SetToggleCommandState(sectionID, cmdID, on and 1 or 0)
  r.RefreshToolbar2(sectionID, cmdID)
end

-- ExtState helpers
local function get(key) return r.GetExtState(NS, key) end
local function set(key, val) r.SetExtState(NS, key, tostring(val or ""), false) end

-- If another instance is running, request it to stop and exit this instance
if get(KEY_RUNNING) == "1" then
  set(KEY_STOP, "1")
  set(KEY_TOKEN, tostring(math.random()) .. os.clock()) -- bump token
  set_toggle(false)
  return
end

-- Mark this as running
local MY_TOKEN = tostring(math.random()) .. os.clock()
set(KEY_TOKEN,   MY_TOKEN)
set(KEY_STOP,    "0")
set(KEY_RUNNING, "1")

-- Show all in mixer
local function mixer_show_all()
  local n = r.CountTracks(0)
  for i = 0, n - 1 do
    local tr = r.GetTrack(0, i)
    r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 1)
  end
end

-- Selection signature (to avoid redundant work)
local function selection_signature()
  local selN = r.CountSelectedTracks(0)
  if selN == 0 then return "NONE" end
  local ids = {}
  for i = 0, selN - 1 do
    local tr = r.GetSelectedTrack(0, i)
    ids[#ids + 1] = r.GetTrackGUID(tr)
  end
  table.sort(ids)
  return table.concat(ids, "|")
end

-- Gather selected tracks plus all their parent folders (recursive)
local function gather_selected_and_parents()
  local show = {}
  local nsel = r.CountSelectedTracks(0)

  local function mark_with_parents(tr)
    local t = tr
    while t do
      if show[t] then break end
      show[t] = true
      t = r.GetParentTrack(t)
    end
  end

  for i = 0, nsel - 1 do
    local tr = r.GetSelectedTrack(0, i)
    if tr then mark_with_parents(tr) end
  end
  return show, nsel
end

-- State
local running  = true
local last_sig = ""

-- Apply visibility rules
function apply_if_needed()
  if not running then return end

  local ntracks = r.CountTracks(0)
  local to_show, sel_count = gather_selected_and_parents()

  if sel_count == 0 then
    -- No selection: show all
    for i = 0, ntracks - 1 do
      local tr = r.GetTrack(0, i)
      r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 1)
    end
  else
    -- Show only selected and all their ancestors
    for i = 0, ntracks - 1 do
      local tr  = r.GetTrack(0, i)
      local vis = to_show[tr] and 1 or 0
      r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", vis)
    end
  end

  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
end

-- Stop and restore
local function stop_and_restore()
  if not running then return end
  running = false
  
  if restore_on_disable then 
    mixer_show_all()
  end
  
  r.TrackList_AdjustWindows(false)
  set_toggle(false)
  set(KEY_RUNNING, "0")
  set(KEY_STOP,    "0")
end

-- Ensure restore on termination
r.atexit(stop_and_restore)

-- Main loop
local function loop()
  if not running then return end

  -- Kill switch and singleton token check
  if get(KEY_STOP) == "1" or get(KEY_TOKEN) ~= MY_TOKEN then
    stop_and_restore()
    return
  end

  local sig = selection_signature()
  if sig ~= last_sig then
    apply_if_needed()
    last_sig = sig
  end

  r.defer(loop)
end

-- Start
set_toggle(true)
apply_if_needed()  -- immediate apply once
loop()