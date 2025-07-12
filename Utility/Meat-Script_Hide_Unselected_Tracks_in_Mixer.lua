-- @provides
--   [main] Meat-Script_Hide_Unselected_Tracks_in_Mixer.lua
-- @description Hide Unselected Tracks in Mixer
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Hide Unselected Tracks in Mixer
--   - Hides busses of unselected tracks in the mixer. 
--   - Recommended to bind this script and the existing action 'Track: Make all tracks visible in TCP and mixer' to Mouse Button 03 & 04.

-- Get the number of tracks
local track_count = reaper.CountTracks(0)

-- Loop through all tracks and update mixer visibility
for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local selected = reaper.IsTrackSelected(track)
    reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", selected and 1 or 0)
end

-- Force UI refresh without closing the mixer
reaper.PreventUIRefresh(1)
reaper.UpdateTimeline()
reaper.Main_OnCommand(40914, 0) -- Track: Refresh all visible tracks
reaper.TrackList_AdjustWindows(false) -- Adjust windows to reflect changes
reaper.PreventUIRefresh(-1)
