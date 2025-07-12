-- @provides
--   [main] Meat-Script_Hide_Tracks_Unselected.lua
-- @description Hide Tracks Unselected
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Hide Tracks Unselected
--   - Hides all unselected tracks in TCP and mixer
--   - When nothing is selected, this script will unhide all tracks.

-- Get the count of selected tracks
local selected_tracks_count = reaper.CountSelectedTracks(0)

-- Get the total number of tracks in the project
local total_tracks_count = reaper.CountTracks(0)

if selected_tracks_count == 0 then
    -- Unhide all tracks if no tracks are selected
    for i = 0, total_tracks_count - 1 do
        local track = reaper.GetTrack(0, i)
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 1) -- Show in MCP
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)  -- Show in TCP
    end
else
    -- Loop through all tracks
    for i = 0, total_tracks_count - 1 do
        local track = reaper.GetTrack(0, i)
        
        -- Check if the current track is selected
        local is_selected = reaper.IsTrackSelected(track)
        
        if not is_selected then
            -- Hide the track by setting its visibility in both TCP and MCP to false
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0) -- Hide in MCP
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)  -- Hide in TCP
        end
    end
end

-- Update the arrange view to reflect the changes
reaper.TrackList_AdjustWindows(false)
