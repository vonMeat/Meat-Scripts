-- @provides
--   [main] Meat-Script_Extend_RegionBounds_to_NearbyItems.lua
-- @description Extend Region Bounds to Nearby Items
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Extend Region Bounds to Nearby Items
--   - Given a timeline selection that overlaps any region boundary, this script will extend the region(s) boundary or boundaries to the nearest item.
--   - Useful when working with many variations, so you avoid having to manually extend the boundary to fit within the items you're playing. 
--   - Recommended to add this script to the 'Ruler/arrange context' menu.

-- Function to get selected time range
function get_selected_time_range()
    local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    return start_time, end_time
end

-- Function to find regions within the selected time range
function get_regions_in_selection(sel_start, sel_end)
    local total_markers = reaper.CountProjectMarkers(0)
    local regions = {}
    for i = 0, total_markers - 1 do
        local _, is_region, rgn_start, rgn_end, _, idx = reaper.EnumProjectMarkers(i)
        if is_region and rgn_start < sel_end and rgn_end > sel_start then
            table.insert(regions, {start = rgn_start, ["end"] = rgn_end, index = idx})
        end
    end
    return regions
end

-- Function to find the first and last media item in a given range
function get_media_boundaries(region_start, region_end)
    local first_start = nil
    local last_end = nil
    local num_items = reaper.CountMediaItems(0)
    
    for i = 0, num_items - 1 do
        local item = reaper.GetMediaItem(0, i)
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_end = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        
        if item_end > region_start and item_start < region_end then
            if not first_start or item_start < first_start then
                first_start = item_start
            end
            if not last_end or item_end > last_end then
                last_end = item_end
            end
        end
    end
    
    return first_start, last_end
end

-- Main function
function adjust_regions_to_media()
    reaper.Undo_BeginBlock()
    local sel_start, sel_end = get_selected_time_range()
    if sel_start == sel_end then
        reaper.ShowMessageBox("Please make a time selection.", "Error", 0)
        return
    end

    local regions = get_regions_in_selection(sel_start, sel_end)
    if #regions == 0 then
        reaper.ShowMessageBox("No regions found within the selection.", "Error", 0)
        return
    end
    
    for _, region in ipairs(regions) do
        local new_start, new_end = get_media_boundaries(region.start, region["end"])
        if new_start and new_end then
            reaper.SetProjectMarker(region.index, true, new_start, new_end, "", 0)
        end
    end
    
    reaper.Undo_EndBlock("Adjust Regions to Media Boundaries", -1)
    reaper.UpdateArrange()
end

adjust_regions_to_media()
