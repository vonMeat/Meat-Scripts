-- @provides
--   [main] Meat-Script_Nuke_Timeline_Selection.lua
-- @description Nuke Timeline Selection
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Nuke Timeline Selection
--   Removes every object that intersects the active timeline selection:
--   - All Media-items
--   - All Project markers and regions that start or overlap inside the selection
--   - All envelope points (track envelopes + item/take envelopes)
--   - EVERYTHING
--
--   - The script is NON-RIPPLE (arrangement length is unchanged).
--   - Recommended to add to the 'Ruler/arrange context' menu.

local r = reaper

------------------------------------------------------------
-- 0) Helpers
------------------------------------------------------------
local function has_time_sel()
  local a,b = r.GetSet_LoopTimeRange( false,false,0,0,false )
  return (b > a), a, b          -- bool, start, end
end

------------------------------------------------------------
-- 1) Delete markers & regions that overlap selection
------------------------------------------------------------
local function delete_markers(sel_start, sel_end)
  local _,num_markers,num_regions = r.CountProjectMarkers(0)
  local total = num_markers + num_regions
  -- walk backwards so indices remain valid
  for i = total-1, 0, -1 do
    local retval,isRgn,pos,rgnEnd,_,idx = r.EnumProjectMarkers(i)
    if retval then
      if (not isRgn and pos >= sel_start and pos <= sel_end) or               -- normal marker
         (isRgn and not (rgnEnd <= sel_start or pos >= sel_end)) then         -- region overlaps sel
        r.DeleteProjectMarker(0, idx, isRgn)
      end
    end
  end
end

------------------------------------------------------------
-- 2) Split items at sel boundaries, then delete middle pieces
------------------------------------------------------------
local function split_items_around(sel_edge)
  -- split every item that straddles sel_edge
  for i = 0, r.CountMediaItems(0)-1 do
    local it = r.GetMediaItem(0,i)
    local s  = r.GetMediaItemInfo_Value(it, "D_POSITION")
    local e  = s + r.GetMediaItemInfo_Value(it, "D_LENGTH")
    if s < sel_edge and e > sel_edge then
      r.SplitMediaItem(it, sel_edge)
    end
  end
end

local function delete_items_in(sel_start, sel_end)
  -- 1) split once at right edge, once at left
  split_items_around(sel_end)
  split_items_around(sel_start)
  -- 2) delete every item that now sits wholly inside
  for i = r.CountMediaItems(0)-1, 0, -1 do
    local it = r.GetMediaItem(0,i)
    local s  = r.GetMediaItemInfo_Value(it, "D_POSITION")
    local e  = s + r.GetMediaItemInfo_Value(it, "D_LENGTH")
    if s >= sel_start and e <= sel_end then
      r.DeleteTrackMediaItem( r.GetMediaItem_Track(it), it )
    end
  end
end

------------------------------------------------------------
-- 3) Delete envelope-points (tracks + take envelopes)
------------------------------------------------------------
local function wipe_envelope_points(env, sel_start, sel_end)
  -- points
  r.DeleteEnvelopePointRange( env, sel_start, sel_end )
  -- automation items (if any) - remove ones that overlap
  local ai_cnt = r.CountAutomationItems and r.CountAutomationItems(env) or 0
  for i = ai_cnt-1, 0, -1 do
    local ai_pos  = r.GetSetAutomationItemInfo(env, i, "D_POSITION", 0, false)
    local ai_len  = r.GetSetAutomationItemInfo(env, i, "D_LENGTH"  , 0, false)
    local ai_end  = ai_pos + ai_len
    if not (ai_end <= sel_start or ai_pos >= sel_end) then
      r.DeleteAutomationItem(env, i)
    end
  end
end

local function delete_automation(sel_start, sel_end)
  -- track envelopes
  for t = 0, r.CountTracks(0)-1 do
    local tr = r.GetTrack(0,t)
    for e = 0, r.CountTrackEnvelopes(tr)-1 do
      wipe_envelope_points( r.GetTrackEnvelope(tr,e), sel_start, sel_end )
    end
  end
  -- take envelopes
  for i = 0, r.CountMediaItems(0)-1 do
    local it   = r.GetMediaItem(0,i)
    local tk   = r.GetMediaItemTake(it, 0)
    if tk then
      for e = 0, r.CountTakeEnvelopes(tk)-1 do
        wipe_envelope_points( r.GetTakeEnvelope(tk,e), sel_start, sel_end )
      end
    end
  end
end

------------------------------------------------------------
-- 4) MAIN
------------------------------------------------------------
local ok, sel_start, sel_end = has_time_sel()
if not ok then
  r.ShowMessageBox("No active time-selection found.", "Delete contents", 0)
  return
end

r.Undo_BeginBlock()
r.PreventUIRefresh(1)

delete_markers(sel_start, sel_end)
delete_items_in(sel_start, sel_end)
delete_automation(sel_start, sel_end)

r.PreventUIRefresh(-1)
r.Undo_EndBlock("Delete EVERYTHING in time-selection", -1)
r.UpdateArrange()
