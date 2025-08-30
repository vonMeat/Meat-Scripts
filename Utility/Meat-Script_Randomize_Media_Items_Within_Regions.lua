-- @provides
--   [main] Meat-Script_Randomize_Media_Items_Within_Regions.lua
-- @description Randomize Media Items Within Regions
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Randomize Media Items Within Regions
--   - Affects any region overlapping a timeline selection.
--   - Works per track (items never cross tracks).
--   - Preserves each item's offset relative to its region start.
--   - Trims items to the destination region bounds after moving.
--   - Recommended to add to 'Ruler/arrange' menu

-- ---------- Small helpers ----------
local function show_message(message, title, message_type)
  return reaper.ShowMessageBox(message, title or "Region Randomizer", message_type or 0)
end

local function get_regions_in_timeline_selection()
  local sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if sel_start == sel_end then
    show_message("Please make a timeline selection.", "Region Randomizer", 2)
    return {}
  end
  local regions = {}
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions
  for i = 0, total - 1 do
    local ok, is_region, pos, rgn_end, name = reaper.EnumProjectMarkers(i)
    if ok and is_region and not (rgn_end <= sel_start or pos >= sel_end) then
      regions[#regions+1] = { start = pos, ["end"] = rgn_end, name = name or ("Region "..(#regions+1)) }
    end
  end
  return regions
end

local function trim_item_to_region(item, region)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_pos + item_len
  local new_start = math.max(item_pos, region.start)
  local new_end   = math.min(item_end, region["end"])
  local new_len   = new_end - new_start
  if new_len > 0 then
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", new_start)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH",   new_len)
  end
end

-- Fisher–Yates + post-fix to ensure derangement (no fixed points when n>1)
local function deranged_indices(n)
  local idx = {}
  for i=1,n do idx[i]=i end
  for i=n,2,-1 do
    local j = math.random(1,i)
    idx[i], idx[j] = idx[j], idx[i]
  end
  if n > 1 then
    for i=1,n do
      if idx[i] == i then
        local j = (i % n) + 1
        idx[i], idx[j] = idx[j], idx[i]
      end
    end
  end
  return idx
end

local function reseed_rng()
  local seed = math.floor((reaper.time_precise() * 1000000) % 2147483647)
  if seed <= 0 then seed = os.time() end
  math.randomseed(seed)
  -- warm-up
  math.random(); math.random(); math.random()
end

-- ---------- Core collection ----------
-- For each region, collect items per track (allowing partial overlaps).
local function collect_region_items_by_track(region)
  local by_track = {}
  local item_count = reaper.CountMediaItems(0)
  for i = 0, item_count - 1 do
    local item = reaper.GetMediaItem(0, i)
    local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local ilen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local iend = ipos + ilen
    if (iend > region.start) and (ipos < region["end"]) then
      local tr = reaper.GetMediaItem_Track(item)
      by_track[tr] = by_track[tr] or {}
      by_track[tr][#by_track[tr]+1] = {
        item     = item,
        position = ipos,
        length   = ilen
      }
    end
  end
  return by_track
end

-- ---------- Main logic ----------
local function swap_items_between_regions()
  local regions = get_regions_in_timeline_selection()
  if #regions < 2 then
    show_message("Please ensure the timeline selection contains at least two regions.", "Region Randomizer", 2)
    return false
  end

  reseed_rng()

  -- Gather items per region, per track
  local region_items_by_track = {}
  local all_tracks_set = {}
  for r = 1, #regions do
    region_items_by_track[r] = collect_region_items_by_track(regions[r])
    for tr,_ in pairs(region_items_by_track[r]) do
      all_tracks_set[tr] = true
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- For every track that appears in any region
  for tr,_ in pairs(all_tracks_set) do
    -- Build unified lists:
    --   slots  -> one slot per encountered item; contains {region_idx, offset}
    --   items  -> the actual item pointers
    local slots, items = {}, {}

    -- We iterate regions in order to keep “slot shape” stable (counts per region persist)
    for r = 1, #regions do
      local region = regions[r]
      local list = (region_items_by_track[r] and region_items_by_track[r][tr]) or {}
      -- Sort items by their position inside the region so the slot spacing is consistent
      table.sort(list, function(a,b) return a.position < b.position end)
      for _, info in ipairs(list) do
        local offset = info.position - region.start
        if offset < 0 then offset = 0 end
        slots[#slots+1] = { region_idx = r, offset = offset }
        items[#items+1] = info.item
      end
    end

    local n = #items
    if n >= 2 then
      -- Fully deranged reassignment so every item goes to a different slot
      local perm = deranged_indices(n)
      for i = 1, n do
        local item = items[perm[i]]
        local slot = slots[i]
        local dest_region = regions[slot.region_idx]
        local new_pos = dest_region.start + slot.offset
        reaper.SetMediaItemInfo_Value(item, "D_POSITION", new_pos)
        trim_item_to_region(item, dest_region)
      end
    else
      -- 0 or 1 item on this track across the regions => nothing sensible to shuffle
      -- no-op
    end
  end

  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Randomize Items Across Regions (Derangement, Per Track)", -1)
  return true
end

-- Run
swap_items_between_regions()