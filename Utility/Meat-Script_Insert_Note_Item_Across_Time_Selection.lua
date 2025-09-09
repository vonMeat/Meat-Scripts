-- @provides
--   [main] Meat-Script_Insert_Note_Item_Across_Time_Selection.lua
-- @description Insert Note Item Across Time Selection
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Insert Note Item Across Time Selection
--   - Must have a single track selected and no existing items within the timeline selection
--   - Prompts for note, inserts note item containing provided text across timeline selection.
--   - Recommended to add to 'Ruler/arrange context' menu

local r = reaper

local function get_time_selection()
  local a, b = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if b and a and b > a then return a, b end
  return nil, nil
end

local function prompt_note_text()
  local ok, s = r.GetUserInputs("Empty Item Note", 1, "Note text:", "")
  if not ok then return nil end
  return s or ""
end

local function get_single_selected_track()
  local n = r.CountSelectedTracks(0)
  if n ~= 1 then return nil end
  return r.GetSelectedTrack(0, 0)
end

local function track_has_overlap_in_range(track, t0, t1)
  local cnt = r.CountTrackMediaItems(track)
  for i = 0, cnt - 1 do
    local it  = r.GetTrackMediaItem(track, i)
    local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
    local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
    local endp = pos + len
    -- overlap if not entirely on the left or right
    if not (endp <= t0 or pos >= t1) then
      return true
    end
  end
  return false
end

local function main()
  -- 1) Validate time selection
  local t0, t1 = get_time_selection()
  if not t0 then
    r.ShowMessageBox("Create a time selection first.", "Error", 0)
    return
  end

  -- 2) Ensure exactly one track is selected
  local track = get_single_selected_track()
  if not track then
    r.ShowMessageBox("Select exactly one track.", "Error", 0)
    return
  end

  -- 3) Ensure the track has no items overlapping the selection
  if track_has_overlap_in_range(track, t0, t1) then
    r.ShowMessageBox("Selected track has items overlapping the time selection.", "Error", 0)
    return
  end

  -- 4) Ask for note text
  local note = prompt_note_text()
  if note == nil then return end

  -- 5) Insert empty item spanning the selection and set its Notes
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local item = r.AddMediaItemToTrack(track)
  if not item then
    r.PreventUIRefresh(-1)
    r.Undo_EndBlock("Insert Empty Note Item", -1)
    r.ShowMessageBox("Could not create item.", "Error", 0)
    return
  end

  r.SetMediaItemInfo_Value(item, "D_POSITION", t0)
  r.SetMediaItemInfo_Value(item, "D_LENGTH",  t1 - t0)
  r.GetSetMediaItemInfo_String(item, "P_NOTES", note, true)

  -- optional: select the new item for convenience
  r.Main_OnCommand(40289, 0) -- Unselect all items
  r.SetMediaItemSelected(item, true)

  r.UpdateItemInProject(item)
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock("Insert Empty Note Item", -1)
  r.UpdateArrange()
end

main()
