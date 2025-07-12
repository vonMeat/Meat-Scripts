-- @provides
--   [main] Meat-Script_NewTrack_Plus.lua
-- @description New Track Plus
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### New Track Plus
--   - Creates a new track based on the **base name** of the **selected track** (or "TRACK" if nothing is selected).
--   - If the selected track is a **folder**, the new track is placed **after all of that folder’s children**, so the new one is at the same hierarchical level as the folder track.
--   - If the selected track is a **child track**, the new track is placed **immediately after it**, preserving its **parent relationship**.
--   - The new track **inherits the color** of the selected track (if the selected track has a custom color).
--   - The newly created track is **auto-selected** after creation.

--------------------------------------------------------------------------------
-- 1) Check if a track with a given name already exists
--------------------------------------------------------------------------------
function track_exists(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if track_name == name then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- 2) Generate the next available name based on a base name
--------------------------------------------------------------------------------
function get_next_name(base_name)
  local counter = 1
  local new_name = base_name .. string.format("_%02d", counter)
  while track_exists(new_name) do
    counter = counter + 1
    new_name = base_name .. string.format("_%02d", counter)
  end
  return new_name
end

--------------------------------------------------------------------------------
-- 3) Given a folder track, find the last track in that folder
--    If folderDepth > 0, keep iterating downward until the folder is closed.
--------------------------------------------------------------------------------
function get_last_track_in_folder(track_idx)
  local track_count = reaper.CountTracks(0)
  if track_idx < 0 or track_idx >= track_count then return track_idx end

  local track = reaper.GetTrack(0, track_idx)
  local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
  
  -- If this track isn't actually a folder opener, just return it
  if folder_depth <= 0 then
    return track_idx
  end

  -- If it starts a folder, we walk forward through tracks until the folder closes
  local depth_sum = folder_depth
  local i = track_idx + 1

  while i < track_count and depth_sum > 0 do
    local t = reaper.GetTrack(0, i)
    local d = reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
    depth_sum = depth_sum + d
    i = i + 1
  end

  -- When depth_sum <= 0 or we run out of tracks, the folder is closed
  -- The last track inside that folder is i-1
  return (i - 1)
end

--------------------------------------------------------------------------------
-- 4) Main function: Create the new track at the correct position & name it
--------------------------------------------------------------------------------
function create_named_track()
  -- Get the last selected track (if any)
  local num_selected = reaper.CountSelectedTracks(0)
  local selected_track = nil

  if num_selected > 0 then
    -- If multiple tracks selected, Reaper's "GetSelectedTrack(0, num_selected-1)"
    -- would give the last one in the selection. We only care about the last selected.
    selected_track = reaper.GetSelectedTrack(0, num_selected - 1)
  end

  -- Figure out the base name from selected track or default "TRACK"
  local base_name
  if selected_track then
    local _, track_name = reaper.GetSetMediaTrackInfo_String(selected_track, "P_NAME", "", false)
    -- Extract the base name by removing any trailing underscore/number
    base_name = track_name:match("(.-)_?%d*$") or track_name
    if base_name == "" then
      base_name = "TRACK"
    end
  else
    base_name = "TRACK"
  end

  -- Generate the next available name
  local new_name = get_next_name(base_name)

  -- Determine the correct insertion index
  local insert_index
  if selected_track then
    local sel_idx = reaper.GetMediaTrackInfo_Value(selected_track, "IP_TRACKNUMBER") - 1
    
    -- If the selected track is a folder opener, jump to the last child
    local last_in_folder = get_last_track_in_folder(sel_idx)
    insert_index = last_in_folder + 1
  else
    -- No track selected => just insert at the end
    insert_index = reaper.CountTracks(0)
  end

  reaper.Undo_BeginBlock()

  -- 1) Insert the new track
  reaper.InsertTrackAtIndex(insert_index, true)
  local new_track = reaper.GetTrack(0, insert_index)

  -- 2) Name the new track
  reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", new_name, true)

  -- 3) Copy the color from the selected track to the new track (only if the selected track has a custom color)
  if selected_track then
    local color = reaper.GetTrackColor(selected_track)
    if color ~= 0 then -- Only set the color if it's not the default (0)
      reaper.SetTrackColor(new_track, color)
    end
  end

  -- 4) If the selected track was a child *and* was closing its folder (folder depth = -1),
  --    we need to adjust it so that we can continue adding siblings at the same level.
  --
  --    Concretely, that means: turn the old track’s depth from -1 to 0
  --    and make our newly inserted track be the “last child” at -1.
  --
  --    This logic ensures that example #1 works:
  --      track_01
  --        track_02 (=-1, last child, selected)
  --    => new track also as child:
  --      track_01
  --        track_02 (=0 now)
  --        track_03 (=-1)
  --------------------------------------------------------------------------------
  if selected_track then
    local sel_folder_depth = reaper.GetMediaTrackInfo_Value(selected_track, "I_FOLDERDEPTH")

    if sel_folder_depth == -1 then
      -- Make the old track a "normal" child (0), keep the folder open
      reaper.SetMediaTrackInfo_Value(selected_track, "I_FOLDERDEPTH", 0)
      -- Make the new track the new last child
      reaper.SetMediaTrackInfo_Value(new_track, "I_FOLDERDEPTH", -1)
    end
  end

  -- 5) Deselect all tracks and select the newly created track
  reaper.Main_OnCommand(40297, 0) -- Unselect all tracks
  reaper.SetTrackSelected(new_track, true) -- Select the new track

  reaper.Undo_EndBlock("Create New Track with Custom Name (Preserve Hierarchy)", -1)
end

--------------------------------------------------------------------------------
-- 5) Run it
--------------------------------------------------------------------------------
create_named_track()