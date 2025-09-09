-- @provides
--   [main] Meat-Script_Swap_Media_Item_Positions.lua
-- @description Swap Media Item Positions
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Swap Media Item Positions
--   - Swaps start position between two selected media items.
--   - Recommended shortcut: "ALT+["

local r = reaper

local function main()
  local n = r.CountSelectedMediaItems(0)
  if n ~= 2 then
    r.ShowMessageBox("Select exactly TWO media items.", "Swap Start Times", 0)
    return
  end

  local itA = r.GetSelectedMediaItem(0, 0)
  local itB = r.GetSelectedMediaItem(0, 1)
  if not itA or not itB then return end

  local posA = r.GetMediaItemInfo_Value(itA, "D_POSITION")
  local posB = r.GetMediaItemInfo_Value(itB, "D_POSITION")

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- swap
  r.SetMediaItemInfo_Value(itA, "D_POSITION", posB)
  r.SetMediaItemInfo_Value(itB, "D_POSITION", posA)

  r.UpdateArrange()
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock("Swap start times of two selected items", -1)
end

main()
