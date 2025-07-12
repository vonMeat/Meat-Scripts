-- @provides
--   [main] Meat-Script_Select_All_Items_Within_Timeline_Selection.lua
-- @description Select All Items Within Timeline Selection
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Select All Items Within Timeline Selection
--   - Selects every media item that overlaps the current time selection.
--   - Recommended shortcut: 'CTRL+A'.

local function main()
  -- Get the current time selection (returns start and end even if loop disabled)
  local sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if sel_end <= sel_start then
    reaper.ShowMessageBox("No timeline selection detected.", "Select Items", 0)
    return
  end

  reaper.Undo_BeginBlock()
  local item_count = reaper.CountMediaItems(0)

  for i = 0, item_count - 1 do
    local item   = reaper.GetMediaItem(0, i)
    local pos    = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len    = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local pos_end = pos + len

    -- Intersection test: item touches the selection at all?
    local in_selection = (pos_end > sel_start) and (pos < sel_end)
    reaper.SetMediaItemSelected(item, in_selection)
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Select items in time selection", -1)
end

main()
