-- @provides
--   [main] Meat-Script_Remove_Empty_Space_Between_Selected_Media_Items.lua
-- @description Remove Empty Space Between Selected Media Items
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Region Renamer
--   Given a media item selection containing two or more items:
--   - > Moves all selected media items within each track to the left, snapping them together while keeping their order.
--   - > Uses the leftmost selected item per track as the anchor.

function remove_gaps_selected_items()
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local num_selected_items = reaper.CountSelectedMediaItems(0)
    if num_selected_items == 0 then
        return -- No media items selected, do nothing
    end

    -- Organize selected items by track
    local track_items = {}

    for i = 0, num_selected_items - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local track = reaper.GetMediaItem_Track(item)

        if not track_items[track] then
            track_items[track] = {}
        end
        table.insert(track_items[track], item)
    end

    -- Process each track separately
    for track, items in pairs(track_items) do
        -- Sort items left to right based on position
        table.sort(items, function(a, b)
            return reaper.GetMediaItemInfo_Value(a, "D_POSITION") < reaper.GetMediaItemInfo_Value(b, "D_POSITION")
        end)

        -- Get the leftmost item as the anchor
        local anchor_position = reaper.GetMediaItemInfo_Value(items[1], "D_POSITION")
        local next_available_position = anchor_position

        -- Move each item left while keeping order
        for _, item in ipairs(items) do
            local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

            -- Move item to the next available position
            reaper.SetMediaItemInfo_Value(item, "D_POSITION", next_available_position)

            -- Update next available position
            next_available_position = next_available_position + item_length
        end
    end

    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Remove Empty Space Between Selected Media Items", -1)
    reaper.UpdateArrange()
end

remove_gaps_selected_items()
