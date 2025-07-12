-- @provides
--   [main] Meat-Script_Reaper_Project_Audit.lua
-- @description Reaper Project Audit (WIP)
-- @version 0.2
-- @author Jeremy Romberg
-- @about
--   ### Reaper Project Audit (WIP)
--   - WIP. USE AT YOUR OWN DISCRETION
-- @changelog
--   0.2 • Added Undo block, UI freeze, faster FX‑signature hashing,
--        safer offline‑file check, and "Copy report to clipboard" option.

-------------------------------------------------------------------
-- Helpers --------------------------------------------------------
-------------------------------------------------------------------
local project = 0 -- 0 == active project

local function file_exists_safe(path)
  return path ~= "" and reaper.file_exists(path)
end

-- Build a lightweight hash for an FX's parameter snapshot
local function hash_params(track, fx, param_count)
  local t = {}
  for p = 0, param_count - 1 do
    t[#t + 1] = string.format("%.5f", reaper.TrackFX_GetParam(track, fx, p))
  end
  return table.concat(t, ",")
end

-------------------------------------------------------------------
-- Main -----------------------------------------------------------
-------------------------------------------------------------------
reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock()

local totalFX      = 0
local fxSignatures = {}      -- fxSignatures[fxName][hash] -> {tracks}
local unusedTracks = {}
local offlineItems = {}

local trackCount = reaper.CountTracks(project)
for t = 0, trackCount - 1 do
  local track      = reaper.GetTrack(project, t)
  local fxCount    = reaper.TrackFX_GetCount(track)
  local itemCount  = reaper.CountTrackMediaItems(track)
  local isMuted    = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1

  -- Unused track = no items *or* muted
  if itemCount == 0 or isMuted then
    unusedTracks[#unusedTracks + 1] = t + 1
  end

  ----------------------------------------------------------------
  -- FX audit
  ----------------------------------------------------------------
  totalFX = totalFX + fxCount
  for fx = 0, fxCount - 1 do
    local _, fxName   = reaper.TrackFX_GetFXName(track, fx, "")
    local paramCount  = reaper.TrackFX_GetNumParams(track, fx)
    local sig         = hash_params(track, fx, paramCount)

    fxSignatures[fxName] = fxSignatures[fxName] or {}
    if not fxSignatures[fxName][sig] then
      fxSignatures[fxName][sig] = { tracks = { t + 1 } }
    else
      table.insert(fxSignatures[fxName][sig].tracks, t + 1)
    end
  end

  ----------------------------------------------------------------
  -- Offline items audit
  ----------------------------------------------------------------
  for i = 0, itemCount - 1 do
    local item   = reaper.GetTrackMediaItem(track, i)
    local take   = reaper.GetActiveTake(item)
    if take then
      local src     = reaper.GetMediaItemTake_Source(take)
      local file    = reaper.GetMediaSourceFileName(src, "")
      if not file_exists_safe(file) then
        offlineItems[#offlineItems + 1] = {track = t + 1, item = i + 1, file = file}
      end
    end
  end
end

-------------------------------------------------------------------
-- Build report ---------------------------------------------------
-------------------------------------------------------------------
local report = {}
local function add(s) report[#report + 1] = s end

add("Project Audit\n\n")
add("Total Plugins: " .. totalFX .. "\n\n")

add("Plugins with identical parameters:\n")
local dupFound = false
for fxName, sigTable in pairs(fxSignatures) do
  for _, info in pairs(sigTable) do
    if #info.tracks > 1 then
      dupFound = true
      add(string.format("%s : Tracks %s\n", fxName, table.concat(info.tracks, ", ")))  
    end
  end
end
if not dupFound then add("None\n") end

add("\nUnused Tracks:\n")
add(#unusedTracks == 0 and "None\n" or table.concat(unusedTracks, ", ") .. "\n")

add("\nOffline Media Items:\n")
if #offlineItems == 0 then
  add("None\n")
else
  for _, itm in ipairs(offlineItems) do
    add(string.format("Track %d, Item %d: %s\n", itm.track, itm.item, itm.file))
  end
end

local fullReport = table.concat(report)

-------------------------------------------------------------------
-- Present report -------------------------------------------------
-------------------------------------------------------------------
local choice = reaper.ShowMessageBox(fullReport .. "\n\nCopy report to clipboard?", "Project Audit", 4)
if choice == 6 then -- 6 == YES
  reaper.CF_SetClipboard(fullReport) -- requires SWS
end

reaper.Undo_EndBlock("Project Audit", -1)
reaper.PreventUIRefresh(-1)
