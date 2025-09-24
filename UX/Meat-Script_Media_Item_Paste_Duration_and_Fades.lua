-- @provides
--   [main] Meat-Script_Media_Item_Paste_Duration_and_Fades.lua
-- @description Media Item Paste Duration and Fades
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Media Item Paste Duration and Fades
--   - Requires companion script 'Meat-Script_Media_Item_Copy_Duration_and_Fades.lua'.
--   - Applies the copied duration and fades of a given media item. Can be applied to several media items at once. 
--   - Any splits are applied from the center of the item.
--   - Recommended shortcut: SHIFT+ALT+V

local r = reaper
local SEC, KEY = "RS_ITEM_FRAME", "DATA"
local EPS = 1e-9

local function get()
  local blob = r.GetExtState(SEC, KEY)
  if blob == "" then return nil end
  local f = load(blob); if not f then return nil end
  local ok, t = pcall(f); if not ok then return nil end
  return t
end

-- Resize around center when we need to grow the item.
local function grow_item_around_center(item, new_len)
  local ip = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local ln = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local mid = ip + ln * 0.5
  local new_start = mid - new_len * 0.5

  -- set new start and length; center remains anchored at 'mid'
  r.SetMediaItemInfo_Value(item, "D_POSITION", new_start)
  r.SetMediaItemInfo_Value(item, "D_LENGTH",  new_len)

  return item, new_start, new_start + new_len, new_len
end

-- Split to keep only the centered window and delete the trims (for shrinking).
local function isolate_center_segment_delete_trims(item, src_len)
  local ip = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local ln = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local ie = ip + ln

  -- If copied frame is significantly longer, grow instead of split.
  if src_len > ln + EPS then
    return grow_item_around_center(item, src_len)
  end

  -- If nearly equal or slightly longer, just keep whole item.
  if src_len >= ln - EPS then
    return item, ip, ie, ln
  end

  -- Otherwise: trim to centered window
  local mid = ip + ln * 0.5
  local t0  = math.max(ip, mid - src_len * 0.5)
  local t1  = math.min(ie, mid + src_len * 0.5)

  local right = (t0 > ip + EPS) and r.SplitMediaItem(item, t0) or item
  if right ~= item then
    r.DeleteTrackMediaItem(r.GetMediaItem_Track(item), item) -- delete left remainder
  end

  local right2 = (t1 < ie - EPS) and r.SplitMediaItem(right, t1) or nil
  if right2 then
    r.DeleteTrackMediaItem(r.GetMediaItem_Track(right2), right2) -- delete right remainder
  end

  local segStart = r.GetMediaItemInfo_Value(right, "D_POSITION")
  local segLen   = r.GetMediaItemInfo_Value(right, "D_LENGTH")
  return right, segStart, segStart + segLen, segLen
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

local function apply_fades(it, fades, segLen)
  if not fades then return end
  local in_len   = clamp(fades.in_len   or 0, 0, segLen)
  local out_len  = clamp(fades.out_len  or 0, 0, segLen)
  local in_auto  = clamp(fades.in_auto  or 0, 0, segLen)
  local out_auto = clamp(fades.out_auto or 0, 0, segLen)

  r.SetMediaItemInfo_Value(it, "D_FADEINLEN",        in_len)
  r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN",       out_len)
  r.SetMediaItemInfo_Value(it, "D_FADEINLEN_AUTO",   in_auto)
  r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN_AUTO",  out_auto)

  if fades.in_shape  then r.SetMediaItemInfo_Value(it, "C_FADEINSHAPE",  fades.in_shape)  end
  if fades.out_shape then r.SetMediaItemInfo_Value(it, "C_FADEOUTSHAPE", fades.out_shape) end
  if fades.in_dir    then r.SetMediaItemInfo_Value(it, "D_FADEINDIR",    fades.in_dir)    end
  if fades.out_dir   then r.SetMediaItemInfo_Value(it, "D_FADEOUTDIR",   fades.out_dir)   end
end

local function paste_to_item(item, clip)
  local segItem, _, _, segLen = isolate_center_segment_delete_trims(item, clip.src_len)
  if not segItem then return end
  apply_fades(segItem, clip.fades, segLen)
end

local function main()
  local clip = get()
  if not clip or not clip.src_len then
    reaper.ShowMessageBox("Nothing copied yet. Run 'Copy Item Frame' first.", "Paste Item Frame", 0)
    return
  end

  local n = r.CountSelectedMediaItems(0)
  if n == 0 then
    reaper.ShowMessageBox("Select one or more items to paste onto.", "Paste Item Frame", 0)
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local items = {}
  for i = 0, n - 1 do items[#items+1] = r.GetSelectedMediaItem(0, i) end
  for _, it in ipairs(items) do paste_to_item(it, clip) end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("RS: Paste Item Frame (center, grow/shrink, apply fades)", -1)
end

main()
