-- @provides
--   [main] Meat-Script_Hide_Tracks_Without_Items_Within_Timeline_Selection.lua
-- @description Hide Tracks Without Items Within Timeline Selection
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Hide Tracks Without Items Within Timeline Selection
--   - Hides tracks that do not have any media items overlapping the current time selection.
--   - Tracks that do have overlapping items remain visible.
--   - For any visible track, all parent tracks in its hierarchy are also unhidden.

local r = reaper

-- Function to check if a track has any media items overlapping the given time selection.
local function track_has_items_in_selection(track, time_start, time_end)
    local item_count = r.CountTrackMediaItems(track)
    for i = 0, item_count - 1 do
        local item = r.GetTrackMediaItem(track, i)
        local item_start = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_start + item_len
        if item_start < time_end and item_end > time_start then
            return true
        end
    end
    return false
end

-- Function to unhide all parent tracks for any track that is visible.
local function unhide_parents_for_visible_tracks()
    local num_tracks = r.CountTracks(0)
    for i = 0, num_tracks - 1 do
        local track = r.GetTrack(0, i)
        if r.GetMediaTrackInfo_Value(track, "B_SHOWINTCP") > 0 then
            local parent = r.GetParentTrack(track)
            while parent do
                r.SetMediaTrackInfo_Value(parent, "B_SHOWINTCP", 1)
                r.SetMediaTrackInfo_Value(parent, "B_SHOWINMIXER", 1)
                parent = r.GetParentTrack(parent)
            end
        end
    end
end

-- Get the current timeline (loop) selection.
local time_start, time_end = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
if time_start == time_end then
    r.ShowMessageBox("Please set a time selection before running the script.", "Error", 0)
    return
end

r.Undo_BeginBlock()

local track_count = r.CountTracks(0)
for i = 0, track_count - 1 do
    local track = r.GetTrack(0, i)
    if track_has_items_in_selection(track, time_start, time_end) then
        r.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)
        r.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 1)
    else
        r.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
        r.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
    end
end

-- Ensure that for any visible track, all parent tracks are unhidden.
unhide_parents_for_visible_tracks()

r.TrackList_AdjustWindows(false)
r.Undo_EndBlock("Hide Tracks Without Items in Timeline Selection (Unhide Parent Tracks)", -1)
