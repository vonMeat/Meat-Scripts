-- @provides
--   [main] Meat-Script_Hide_Tracks_Nested.lua
-- @description Hide Tracks Nested
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Copy Selected Take Name to Clipboard
--   - Toggle visibility of nested tracks for any selected track; affects TCP and mixer.
--   - If no tracks are selected, toggle visibility for all nested tracks.

-------------------------------------
-- Helper: Check if a track is a descendant of a parent track (supports nested folders)
-------------------------------------
local function is_descendant(child_track, parent_track)
    local current_parent = reaper.GetParentTrack(child_track)
    while current_parent ~= nil do
        if current_parent == parent_track then
            return true
        end
        current_parent = reaper.GetParentTrack(current_parent) -- Check higher ancestors
    end
    return false
end

-------------------------------------
-- Toggle visibility for ALL descendants of a track (including nested folders)
-------------------------------------
local function toggle_descendants_visibility(parent_track, hide)
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        if is_descendant(track, parent_track) then
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", hide and 0 or 1)
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", hide and 0 or 1)
        end
    end
end

-------------------------------------
-- Main Logic
-------------------------------------
local total_tracks = reaper.CountTracks(0)
local selected_tracks_count = reaper.CountSelectedTracks(0)

if selected_tracks_count > 0 then
    -- Toggle nested tracks for SELECTED TRACKS
    for i = 0, selected_tracks_count - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        if reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1 then -- Check if it's a folder
            -- Determine current visibility state
            local any_visible = false
            for j = 0, total_tracks - 1 do
                local nested_track = reaper.GetTrack(0, j)
                if is_descendant(nested_track, track) then
                    if reaper.GetMediaTrackInfo_Value(nested_track, "B_SHOWINTCP") == 1 then
                        any_visible = true
                        break
                    end
                end
            end
            
            -- Toggle ALL descendants
            toggle_descendants_visibility(track, any_visible)
        end
    end
else
    -- Toggle ALL nested tracks in the project
    local should_hide = false
    
    -- Check if any nested track is visible
    for i = 0, total_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        if reaper.GetParentTrack(track) ~= nil then
            if reaper.GetMediaTrackInfo_Value(track, "B_SHOWINTCP") == 1 then
                should_hide = true
                break
            end
        end
    end
    
    -- Toggle all nested tracks
    for i = 0, total_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        if reaper.GetParentTrack(track) ~= nil then
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", should_hide and 0 or 1)
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", should_hide and 0 or 1)
        end
    end
end

reaper.TrackList_AdjustWindows(false)