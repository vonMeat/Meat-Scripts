-- @provides
--   [main] Meat-Script_Move_Selected_Items_to_Other_Selected_Track.lua
-- @description Move Selected Items to Other Selected Track
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Move Selected Items to Other Selected Track
--   - Two-track mode: exactly two tracks selected; only one may contain selected items; moves those to the other.
--   - Single-track mode: exactly one track selected; it must contain no selected items; moves all other selected items onto it.
--   - Preserves timeline positions
--   - Script warns you if there will be overlaps in media items caused by the script on the new track.
--   - Recommended shortcut : '/'

local function showError(msg)
  reaper.ShowMessageBox(msg, "Error", 0)
end

local function showWarning(msg)
  return reaper.ShowMessageBox(msg, "Warning", 1) == 1 -- OK = 1
end

local function getSelectedTracks()
  local t = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    t[#t+1] = reaper.GetSelectedTrack(0, i)
  end
  return t
end

local function getSelectedItemsOnTrack(track)
  local items = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    if reaper.IsMediaItemSelected(it) then
      items[#items+1] = it
    end
  end
  return items
end

-- Returns true if any moved item overlaps an existing item on destTrack
local function willOverlapExisting(destTrack, itemsToMove)
  for _, src in ipairs(itemsToMove) do
    local sS = reaper.GetMediaItemInfo_Value(src, "D_POSITION")
    local sE = sS + reaper.GetMediaItemInfo_Value(src, "D_LENGTH")
    for i = 0, reaper.CountTrackMediaItems(destTrack) - 1 do
      local tgt = reaper.GetTrackMediaItem(destTrack, i)
      local tS  = reaper.GetMediaItemInfo_Value(tgt, "D_POSITION")
      local tE  = tS + reaper.GetMediaItemInfo_Value(tgt, "D_LENGTH")
      if not (sE <= tS or sS >= tE) then
        return true
      end
    end
  end
  return false
end

-- Returns true if any two moved items from different tracks overlap in time
local function movedItemsOverlapDiffTracks(items)
  for i = 1, #items - 1 do
    local a = items[i]
    local aTr = reaper.GetMediaItemTrack(a)
    local aS  = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
    local aE  = aS + reaper.GetMediaItemInfo_Value(a, "D_LENGTH")
    for j = i + 1, #items do
      local b = items[j]
      if reaper.GetMediaItemTrack(b) ~= aTr then
        local bS = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
        local bE = bS + reaper.GetMediaItemInfo_Value(b, "D_LENGTH")
        if not (aE <= bS or aS >= bE) then
          return true
        end
      end
    end
  end
  return false
end

local function moveItemsToTrack(items, destTrack)
  for _, it in ipairs(items) do
    reaper.MoveMediaItemToTrack(it, destTrack)
  end
end

-- MAIN
reaper.Undo_BeginBlock()

local selTracks   = getSelectedTracks()
local totalSelItm = reaper.CountSelectedMediaItems(0)

if #selTracks == 2 then
  -- Two-track mode
  local t1, t2   = selTracks[1], selTracks[2]
  local t1_items = getSelectedItemsOnTrack(t1)
  local t2_items = getSelectedItemsOnTrack(t2)

  if #t1_items > 0 and #t2_items > 0 then
    showError("Only one of the two selected tracks may have selected items.")
    return
  end

  local fromTrack, toTrack, items
  if #t1_items > 0 then
    fromTrack, toTrack, items = t1, t2, t1_items
  else
    fromTrack, toTrack, items = t2, t1, t2_items
  end

  local overlapExisting = willOverlapExisting(toTrack, items)
  local overlapMoved    = movedItemsOverlapDiffTracks(items)
  if overlapExisting or overlapMoved then
    if not showWarning("Some items will overlap on the destination track. Proceed?") then
      return
    end
  end

  moveItemsToTrack(items, toTrack)

elseif #selTracks == 1 then
  -- Single-track (destination) mode
  local destTrack   = selTracks[1]
  local destItems   = getSelectedItemsOnTrack(destTrack)
  if #destItems > 0 then
    showError("The selected track cannot contain selected items when used as destination.")
    return
  end

  local itemsToMove = {}
  for i = 0, totalSelItm - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    if reaper.GetMediaItemTrack(it) ~= destTrack then
      itemsToMove[#itemsToMove+1] = it
    end
  end

  if #itemsToMove == 0 then
    showError("No selected media items from other tracks to move.")
    return
  end

  local overlapExisting = willOverlapExisting(destTrack, itemsToMove)
  local overlapMoved    = movedItemsOverlapDiffTracks(itemsToMove)
  if overlapExisting or overlapMoved then
    if not showWarning("Some items will overlap on the destination track. Proceed?") then
      return
    end
  end

  moveItemsToTrack(itemsToMove, destTrack)

else
  showError("Please select either one track (as destination) or two tracks total.")
  return
end

reaper.UpdateArrange()
reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("Move Selected Media Items to Track", -1)
