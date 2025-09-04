-- @provides
--   [main] Meat-Script_Space_SFX_Variations_by_Markers.lua
-- @description Space SFX Variations by Markers
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Space SFX Variations by Markers
--   - Make a timeline selection of a set of markers where SFX variations may be overlapping (e.g. when producing foley)
--   - Each marker inside the selection is considered a variation start.
--   - Items belong to a variation if their START is inside that variation's boundary i.e. before the next marker.
--   - The last variation's right boundary = max end among all items that overlap the time selection.
--   - Keeps the first variation anchored. For each next variation, inserts empty space defined by user padding value.
--   - Rest of the project is pushed rightward relative to the amount of time added by the script operation.
--   - Regions created for each variation for easy rendering. Naming based off user provided input (default 'SFX)

local r = reaper

------------------------------------------------------------
-- Debug helpers
------------------------------------------------------------
local DEBUG = false
local function log(s) if DEBUG then r.ShowConsoleMsg(tostring(s) .. "\n") end end
local function hdr(s) if DEBUG then r.ShowConsoleMsg(("\n==== %s ====\n"):format(s)) end end

------------------------------------------------------------
-- Constants / small utils
------------------------------------------------------------
local ACTION_INSERT_EMPTY_SPACE = 40200 -- Time selection: Insert empty space at time selection (moving later items)
local EPS = 1e-12

local function ts_bounds()
  local a, b = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if a and b and b > a then return a, b end
  return nil, nil
end

local function ask_pad(def)
  local ok, s = r.GetUserInputs("Spacing between variations", 1, "Padding seconds:", tostring(def or 1.0))
  if not ok then return nil end
  s = tostring(s):gsub(",", ".")
  local v = tonumber(s)
  if not v or v < 0 then
    r.ShowMessageBox("Enter a non-negative number.", "Invalid input", 0)
    return nil
  end
  return v
end

------------------------------------------------------------
-- Project introspection
------------------------------------------------------------
-- Global bounds (earliest item start, latest item end) across entire project
local function project_item_bounds()
  local min_s, max_e = math.huge, -math.huge
  local nt = r.CountTracks(0) or 0
  for ti = 0, nt - 1 do
    local tr = r.GetTrack(0, ti)
    if tr then
      local ni = r.CountTrackMediaItems(tr) or 0
      for ii = 0, ni - 1 do
        local it = r.GetTrackMediaItem(tr, ii)
        if it then
          local p = r.GetMediaItemInfo_Value(it, "D_POSITION") or 0.0
          local l = r.GetMediaItemInfo_Value(it, "D_LENGTH")   or 0.0
          if p < min_s then min_s = p end
          local e = p + l
          if e > max_e then max_e = e end
        end
      end
    end
  end
  if min_s == math.huge then return nil, nil end
  return min_s, max_e
end

-- Count items whose start >= t (used to explain when 40200 appears to "do nothing")
local function count_items_at_or_after(t)
  local c = 0
  local nt = r.CountTracks(0) or 0
  for ti = 0, nt - 1 do
    local tr = r.GetTrack(0, ti)
    if tr then
      local ni = r.CountTrackMediaItems(tr) or 0
      for ii = 0, ni - 1 do
        local it = r.GetTrackMediaItem(tr, ii)
        if it then
          local p = r.GetMediaItemInfo_Value(it, "D_POSITION") or 0.0
          if p >= t then c = c + 1 end
        end
      end
    end
  end
  return c
end

------------------------------------------------------------
-- Marker / window helpers
------------------------------------------------------------
-- Collect normal markers inside [t0, t1] (end-inclusive). Works with v3 or older API.
local function markers_in_range(t0, t1)
  local out = {}
  if type(r.EnumProjectMarkers3) == "function" then
    local idx = 0
    while true do
      local retval, isrgn, pos, rgnend, name, markIdx, color = r.EnumProjectMarkers3(0, idx)
      if retval == 0 then break end
      if not isrgn and pos and pos >= t0 and pos <= t1 then
        out[#out+1] = { idx = markIdx, pos = pos, name = name or "", color = color or 0 }
      end
      idx = idx + 1
    end
  else
    local _, num_markers, num_regions = r.CountProjectMarkers(0)
    local total = (num_markers or 0) + (num_regions or 0)
    for i = 0, total - 1 do
      local retval, isrgn, pos, rgnend, name, markIdx = r.EnumProjectMarkers(i)
      if retval ~= 0 and not isrgn and pos and pos >= t0 and pos <= t1 then
        out[#out+1] = { idx = markIdx, pos = pos, name = name or "", color = 0 }
      end
    end
  end
  table.sort(out, function(a, b) return a.pos < b.pos end)

  -- Remove exact-duplicate positions
  local dedup, lastpos = {}, nil
  for _, m in ipairs(out) do
    if not lastpos or math.abs(m.pos - lastpos) > EPS then
      dedup[#dedup+1] = m
      lastpos = m.pos
    end
  end
  return dedup
end

-- Longest end among items overlapping [t0, t1]
local function longest_tail(t0, t1)
  local max_end = t1
  local nt = r.CountTracks(0) or 0
  for ti = 0, nt - 1 do
    local tr = r.GetTrack(0, ti)
    if tr then
      local ni = r.CountTrackMediaItems(tr) or 0
      for ii = 0, ni - 1 do
        local it  = r.GetTrackMediaItem(tr, ii)
        if it then
          local pos = r.GetMediaItemInfo_Value(it, "D_POSITION") or 0.0
          local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")   or 0.0
          local fin = pos + len
          if pos < t1 and fin > t0 and fin > max_end then
            max_end = fin
          end
        end
      end
    end
  end
  return max_end
end

-- Build variation windows: [m[i], m[i+1]) except last -> [m[last], last_right]
-- NOTE: We'll bucket by OVERLAP with these windows (not start-in-window).
local function build_vars(markers, last_right)
  local vars = {}
  for i, m in ipairs(markers) do
    local right = (i < #markers) and markers[i+1].pos or last_right
    if right < m.pos then right = m.pos end
    vars[#vars+1] = { L = m.pos, R = right, m = m }
  end
  return vars
end

-- Assign items by OVERLAP with [L, R)
local function bucket_items(vars)
  local B = {}
  for i = 1, #vars do B[i] = { items = {}, max = vars[i].L } end

  local nt = r.CountTracks(0) or 0
  for ti = 0, nt - 1 do
    local tr = r.GetTrack(0, ti)
    if tr then
      local ni = r.CountTrackMediaItems(tr) or 0
      for ii = 0, ni - 1 do
        local it  = r.GetTrackMediaItem(tr, ii)
        if it then
          local pos = r.GetMediaItemInfo_Value(it, "D_POSITION") or 0.0
          local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")   or 0.0
          local fin = pos + len
          for k, v in ipairs(vars) do
            if (pos < v.R) and (fin > v.L) then
              B[k].items[#B[k].items+1] = it
              if fin > B[k].max then B[k].max = fin end
              break
            end
          end
        end
      end
    end
  end
  return B
end

-- Safe marker move; preserve existing name/ID
local function shift_marker(m, new_pos)
  if not m then return end
  if type(reaper.SetProjectMarker2) == "function" then
    -- Correct SetProjectMarker2 signature:
    -- SetProjectMarker2(proj, markrgnindexnumber, isrgn, pos, rgnend, name, color)
    reaper.SetProjectMarker2(0, m.idx, false, new_pos, 0, m.name or "", m.color or 0)
  else
    -- Legacy fallback
    reaper.SetProjectMarker(m.idx, false, new_pos, 0, m.name or "")
  end
end


------------------------------------------------------------
-- Insert empty space with full debug (mirrors your reference script)
------------------------------------------------------------
-- NOTE: Action 40200 only shifts *content that starts at/after the selection*.
-- If you insert at the current tail and nothing is later, it will look like a no-op (we log this).
local function insert_space_exact_debug(at, dur, label)
  if not dur or dur <= 0 then
    hdr("Insert Space — SKIPPED")
    log(("Reason: dur<=0 (%.9f)"):format(dur or -1))
    return
  end

  hdr("Insert Space — BEGIN " .. (label or ""))
  log(("Insert at: %.6f  dur: %.6f"):format(at, dur))

  local min_before, max_before = project_item_bounds()
  log(("Project tail BEFORE: start=%.6f end=%.6f span=%.6f"):format(min_before or -1, max_before or -1, ((max_before or 0)-(min_before or 0))))
  local later_count = count_items_at_or_after(at)
  log(("Items with start >= insert point: %d"):format(later_count))
  if later_count == 0 then
    log("NOTE: 40200 only moves later content; inserting at the tail may look like a no-op (expected).")
  end

  -- Save selection & loop, and link state (same pattern as your working script)
  local ts_s, ts_e = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local lp_s, lp_e = r.GetSet_LoopTimeRange(false, true,  0, 0, false)
  local linked = r.GetToggleCommandState(40385) == 1 -- Options: Loop points linked to time selection
  log(("Loop linked: %s"):format(linked and "ON" or "OFF"))

  local cur = r.GetCursorPosition()
  if linked then r.Main_OnCommand(40385, 0) end -- temporarily unlink

  -- Temporary time selection at [at, at+dur]
  r.GetSet_LoopTimeRange(true, false, at, at + dur, false)
  log("Calling native action 40200 (Insert empty space at time selection)")
  r.Main_OnCommand(ACTION_INSERT_EMPTY_SPACE, 0)  -- mirrors your insert script exactly :contentReference[oaicite:1]{index=1}

  -- Restore selection & loop
  r.GetSet_LoopTimeRange(true, false, ts_s or 0, ts_e or 0, false)
  r.GetSet_LoopTimeRange(true, true,  lp_s or 0, lp_e or 0, false)
  if linked then r.Main_OnCommand(40385, 0) end
  r.SetEditCurPos(cur, false, false)

  local min_after, max_after = project_item_bounds()
  log(("Project tail AFTER : start=%.6f end=%.6f span=%.6f"):format(min_after or -1, max_after or -1, ((max_after or 0)-(min_after or 0))))
  log(("Observed end delta: %.6f"):format(((max_after or 0) - (max_before or 0))))
  hdr("Insert Space — END " .. (label or ""))
end

-----------------------------------------------------------
-- Region helpers
-----------------------------------------------------------
-- Prompt once for the base region name (e.g., "Foley Var")
local function ask_region_basename(def)
  local ok, s = reaper.GetUserInputs("Name for variations", 1, "Region base name:", tostring(def or "Variation"))
  if not ok then return nil end
  s = (s or ""):gsub("^%s*(.-)%s*$", "%1")
  if s == "" then s = "Variation" end
  return s
end

-- Add a region [start, finish] with a numbered name: "<base> 01", "<base> 02", ...
local function add_region(start_pos, end_pos, base, idx1)
  if not start_pos or not end_pos or end_pos <= start_pos then return end
  base = (base or "SFX"):gsub("[<>]", "")         -- keep it clean
  local name = string.format("%s_%02d", base, idx1 or 1)
  reaper.AddProjectMarker2(0, true, start_pos, end_pos, name, -1, 0)
end

------------------------------------------------------------
-- Main (airtight order: compute added -> insert at tail -> move)
------------------------------------------------------------
local function main()
  reaper.ClearConsole()

  local t0, t1 = ts_bounds()
  if not t0 then
    reaper.ShowMessageBox("Create a time selection first.", "Error", 0)
    return
  end

  -- Ask padding first, then the base region name
  local pad = ask_pad(1.0)
  if not pad then return end
  local base = ask_region_basename("SFX")
  if not base then return end
  hdr("Config"); log(("Pad=%.6f  Base='%s'"):format(pad, base))

  -- Markers inside selection (end-inclusive)
  local markers = markers_in_range(t0, t1)
  if #markers < 2 then
    reaper.ShowMessageBox("Need at least two markers in the selection.", "Nothing to do", 0)
    return
  end

  hdr("Markers in selection")
  for i, m in ipairs(markers) do
    log(string.format("[%02d] idx=%d pos=%.6f name='%s'", i, m.idx or -1, m.pos or -1, m.name or ""))
  end

  -- Variation windows and item buckets (by OVERLAP)
  local last_marker_pos = markers[#markers].pos
  local lt         = longest_tail(t0, t1)
  local last_right = math.max(lt, last_marker_pos)
  log(string.format("last_marker_pos=%.6f  longest_tail=%.6f  last_right=%.6f", last_marker_pos, lt, last_right))

  local vars = build_vars(markers, last_right)
  hdr("Variation windows [L, R)")
  for i, v in ipairs(vars) do
    log(string.format("var[%02d] [%.6f, %.6f) name='%s'", i, v.L, v.R, v.m.name or ""))
  end

  local B = bucket_items(vars)

  -- Track min start & max end per bucket (pre-move)
  local mins, maxs = {}, {}
  for i = 1, #vars do
    mins[i], maxs[i] = math.huge, vars[i].L
    local b = B[i]
    for _, it in ipairs(b.items) do
      local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION") or 0.0
      local l = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")   or 0.0
      local e = p + l
      if p < mins[i] then mins[i] = p end
      if e > maxs[i] then maxs[i] = e end
    end
    if mins[i] == math.huge then mins[i] = vars[i].L end
    if maxs[i] < vars[i].L then maxs[i] = vars[i].R end
  end

  -- Project bounds BEFORE
  local min_before, max_before = project_item_bounds()
  if not min_before then
    reaper.ShowMessageBox("No media items in project.", "Error", 0)
    return
  end
  hdr("Project bounds BEFORE")
  log(string.format("start=%.6f end=%.6f span=%.6f", min_before, max_before, max_before - min_before))

  -- Compute per-variation shifts (first stays anchored)
  local shifts = {}
  shifts[1] = 0.0
  local running_max_end = maxs[1]
  for i = 2, #vars do
    local need_at = running_max_end + pad
    local cur_m   = vars[i].m.pos
    local d       = need_at - cur_m
    if not d or d ~= d or d < 0 then d = 0 end
    shifts[i] = d
    local new_end_i = (maxs[i] or vars[i].R) + d
    if new_end_i > running_max_end then running_max_end = new_end_i end
  end

  hdr("Shifts")
  for i = 1, #vars do log(string.format("shift[%02d] = %.6f", i, shifts[i] or 0)) end

  -- Insert based on last affected var only
  local last_end_before     = maxs[#vars] or vars[#vars].R
  local shift_last          = shifts[#vars] or 0
  local predicted_last_end  = last_end_before + shift_last
  local insert_delta        = predicted_last_end - last_end_before
  if insert_delta < 0 or insert_delta ~= insert_delta then insert_delta = 0 end

  -- Wrap EVERYTHING in a single undo block
  reaper.Undo_BeginBlock2(0)
  reaper.PreventUIRefresh(1)

  -- 1) Insert empty space at the tail of the last affected var (pre-move)
  if insert_delta > 0 then
    insert_space_exact_debug(last_end_before, insert_delta, "pre-move@last-affected-end")
  else
    hdr("Insert Space — SKIPPED"); log("Reason: insert_delta = 0")
  end

  -- 2) Move items & markers per shift
  local curpos = reaper.GetCursorPosition()
  for i = 2, #vars do
    local d = shifts[i]
    if d and d > 0 then
      for _, it in ipairs(B[i].items) do
        if reaper.ValidatePtr2(0, it, "MediaItem*") then
          local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
          reaper.SetMediaItemInfo_Value(it, "D_POSITION", p + d)
        end
      end
      shift_marker(vars[i].m, vars[i].m.pos + d)  -- keeps original name & color
    end
  end

  -- 3) Create one region per variation using:
  --    start = earliest item start (after shift), end = finishing media end (after shift)
  for i = 1, #vars do
    local d = shifts[i] or 0
    local rgn_start = mins[i] + d
    local rgn_end   = maxs[i] + d
    -- If a bucket had no items at all, skip the region
    if #B[i].items > 0 then
      add_region(rgn_start, rgn_end, base, i)
    end
  end

  reaper.UpdateArrange()
  reaper.SetEditCurPos(curpos, false, false)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(0, "Space Foley Variations by Markers (fast) + regions", -1)
end

main()
