-- @provides
--   [main] Meat-Script_GUI_Layout_Manager.lua
-- @description Layout Manager GUI
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Layout Manager
--   - Save up to 20 named layouts; preserved per project.
--   - Click + Add slot (bottom center) to create a new layout.
--   - 'Delete' button removes a saved layout from the list.
--   - 'Show All' button unhides any hidden tracks from TCP and MCP view.
--   - Use text field at the top and select 'Filter Tracks' to show only tracks containing the filtered text.
-- @extrequires ReaImGui

local r = reaper

-- Settings
local INIT_W, INIT_H = 522, 180
local EXT_NAMESPACE  = "RS_VIS_LAYOUT_V2"
local MAX_SLOTS      = 20

-- Show All settings
local NAME_W   = 280
local SAVE_W   = 64
local LOAD_W   = 64
local SELECTALL_W = 74
local FILTER_BTN_W = 80
local SP       = -39

-- ReaImGui guard
if not r.ImGui_CreateContext then
  r.ShowMessageBox("ReaImGui extension not found.\nInstall via ReaPack.", "Error", 0)
  return
end

-- Small utils
local function guid_str(tr) return r.GetTrackGUID(tr) end
local function now_str() return os.date("%Y-%m-%d %H:%M") end

-- Serializer (numbers/strings/booleans/tables with string keys)
local function esc_str(s) return string.format("%q", s or "") end
local function serialize(v)
  local t = type(v)
  if t == "number" then return tostring(v)
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "string" then return esc_str(v)
  elseif t == "table" then
    local parts = {}
    for k,val in pairs(v) do
      local kt = type(k)
      if     kt=="number" then parts[#parts+1] = serialize(val)
      elseif kt=="string" then parts[#parts+1] = string.format("[%s]=%s", esc_str(k), serialize(val))
      end
    end
    return "{"..table.concat(parts,",").."}"
  end
  return "nil"
end
local function encode(tbl) return "return "..serialize(tbl) end
local function decode(blob)
  if not blob or blob=="" then return nil end
  local f = load(blob); if not f then return nil end
  local ok,t = pcall(f); if ok and type(t)=="table" then return t end
end

-- Project persistence
local proj = 0
local function proj_get(k)
  local _, v = reaper.GetProjExtState(0, EXT_NAMESPACE, k)  -- two returns: retval, value
  return v
end
local function proj_set(k,v) r.SetProjExtState(proj, EXT_NAMESPACE, k, v or "") end
local function save_all(slots) proj_set("slots", encode(slots)) end
local function load_all()
  local blob = proj_get("slots")
  local t = decode(blob)
  return type(t)=="table" and t or {}
end

-- Capture / apply
local function capture_layout(name)
  local t = { name = name or "", saved_at = now_str(), tracks = {} }
  local n = r.CountTracks(0)
  for i=0,n-1 do
    local tr  = r.GetTrack(0,i)
    local gid = guid_str(tr)
    local tcp = r.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP")   or 1
    local mcp = r.GetMediaTrackInfo_Value(tr, "B_SHOWINMIXER") or 1
    t.tracks[gid] = { tcp = tcp, mcp = mcp }
  end
  return t
end

local function apply_layout(layout)
  if not layout or not layout.tracks then return end
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local n = r.CountTracks(0)
  for i=0,n-1 do
    local tr  = r.GetTrack(0,i)
    local gid = guid_str(tr)
    local s   = layout.tracks[gid]
    if s then
      r.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP",   s.tcp or 1)
      r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", s.mcp or 1)
    end
  end
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock("Restore Layout: "..(layout.name or ""), -1)
end

-- State
local slots = load_all()
if #slots == 0 then
  slots = { { name = "Layout 01", data = nil } }
end

-- Filter 
local filter_text = ""

-- Show All
local function show_all()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP",   1)
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 1)
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Show All Tracks (TCP + Mixer)", -1)
end

-- ─────────────────────────── Track Filter Helpers ───────────────────────────
local function add_to_set(set, tr)
  if tr then set[reaper.GetTrackGUID(tr)] = true end
end

local function show_hierarchy_for_match(idx, show_set)
  local tr        = reaper.GetTrack(0, idx)
  local depth     = reaper.GetTrackDepth(tr)
  local track_cnt = reaper.CountTracks(0)

  -- matched track
  add_to_set(show_set, tr)

  -- descendants (if folder parent)
  for i = idx + 1, track_cnt - 1 do
    local t2 = reaper.GetTrack(0, i)
    local d2 = reaper.GetTrackDepth(t2)
    if d2 > depth then
      add_to_set(show_set, t2)
    else
      break
    end
  end

  -- ancestors (if child)
  local parent = reaper.GetParentTrack(tr)
  while parent do
    add_to_set(show_set, parent)
    parent = reaper.GetParentTrack(parent)
  end
end

local function filter_tracks_by_text(pattern)
  if not pattern or pattern == "" then return end
  local patt = pattern:lower()
  local track_cnt = reaper.CountTracks(0)

  -- 1) collect matches by name
  local matches = {}
  for i = 0, track_cnt - 1 do
    local tr      = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if (name or ""):lower():find(patt, 1, true) then
      matches[#matches+1] = i
    end
  end
  if #matches == 0 then
    reaper.ShowMessageBox("No tracks contain:\n\n  " .. pattern, "Filter Tracks", 0)
    return
  end

  -- 2) build required visibility set (matches + descendants + ancestors)
  local show_set = {}
  for _, idx in ipairs(matches) do
    show_hierarchy_for_match(idx, show_set)
  end

  -- 3) apply visibility + un-fold folders
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  for i = 0, track_cnt - 1 do
    local tr         = reaper.GetTrack(0, i)
    local guid       = reaper.GetTrackGUID(tr)
    local shouldShow = show_set[guid] and 1 or 0

    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP",   shouldShow)
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", shouldShow)

    if shouldShow == 1 and reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 then
      reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERCOMPACT", 0)  -- expand folder
    end
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Filter Tracks: " .. pattern, -1)
end


-- UI
local ctx   = r.ImGui_CreateContext("Track-Visibility Layouts (v2)")
local flags = r.ImGui_WindowFlags_NoCollapse()

local function draw_row(idx, slot)
  r.ImGui_PushID(ctx, idx)
  local changed = false

  if r.ImGui_Button(ctx, "Save##"..idx) then
    slot.data = capture_layout(slot.name ~= "" and slot.name or ("Layout "..string.format("%02d", idx)))
    slot.data.name = slot.name ~= "" and slot.name or slot.data.name
    changed = true
  end

  r.ImGui_SameLine(ctx)
  local canLoad = slot.data ~= nil

  -- Make disabled widgets extra faint (scoped to just this button)
  if reaper.ImGui_StyleVar_DisabledAlpha then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_DisabledAlpha(), 0.25) -- default is ~0.60
  else
    -- Fallback for very old ReaImGui: reduce overall alpha
    local STYLE_ALPHA = reaper.ImGui_StyleVar_Alpha and reaper.ImGui_StyleVar_Alpha() or 0
    reaper.ImGui_PushStyleVar(ctx, STYLE_ALPHA, 0.35)
  end

  reaper.ImGui_BeginDisabled(ctx, not canLoad)
  if reaper.ImGui_Button(ctx, "Load##"..idx) then
    apply_layout(slot.data)
  end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_PopStyleVar(ctx)


  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 280)
  local name = slot.name or ""
  local rv, newname = r.ImGui_InputText(ctx, "##name"..idx, name)
  if rv then slot.name = newname; changed = true end

  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Delete##"..idx) then
    table.remove(slots, idx)
    changed = true
    r.ImGui_PopID(ctx)
    return true, true
  end

  r.ImGui_SameLine(ctx)
  if slot.data and slot.data.saved_at then
    r.ImGui_TextDisabled(ctx, "saved "..slot.data.saved_at)
  else
    r.ImGui_TextDisabled(ctx, "(empty)")
  end

  r.ImGui_PopID(ctx)
  return changed, false
end

local function loop()
  r.ImGui_SetNextWindowSize(ctx, INIT_W, INIT_H, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, "Layout Manager", true, flags)
  if visible then
  
    local rowStartX = r.ImGui_GetCursorPosX(ctx)
    
    -- Header row
    r.ImGui_SetCursorPosX(ctx, rowStartX)
    if r.ImGui_Button(ctx, "Show All", SELECTALL_W, 0) then
      show_all()
    end
    
    -- Filter text field (same width as layout names)
    r.ImGui_SameLine(ctx)
    r.ImGui_SetNextItemWidth(ctx, NAME_W)
    do
      local rv, txt = r.ImGui_InputText(ctx, "##filter_text", filter_text or "")
      if rv then filter_text = txt end
    end
    
    -- Filter button; faint/disabled when field is empty
    local canFilter = (filter_text or "") ~= ""
    if reaper.ImGui_StyleVar_DisabledAlpha then
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_DisabledAlpha(), 0.25)
    else
      local STYLE_ALPHA = r.ImGui_StyleVar_Alpha and r.ImGui_StyleVar_Alpha() or 0
      r.ImGui_PushStyleVar(ctx, STYLE_ALPHA, 0.35)
    end

    r.ImGui_SameLine(ctx)
    r.ImGui_BeginDisabled(ctx, not canFilter)
    if r.ImGui_Button(ctx, "Filter Tracks", FILTER_BTN_W, 0) then
      filter_tracks_by_text(filter_text)
    end
    r.ImGui_EndDisabled(ctx)
    r.ImGui_PopStyleVar(ctx)
    
    r.ImGui_Separator(ctx)

    local any_changed = false
    local i = 1
    while i <= #slots do
      local slot = slots[i]
      local chg, deleted = draw_row(i, slot)
      any_changed = any_changed or chg
      if not deleted then i = i + 1 end
    end

    r.ImGui_Dummy(ctx, 1, 6)
    local avail_w = r.ImGui_GetWindowWidth(ctx)
    local btn_w   = 120
    r.ImGui_SetCursorPosX(ctx, (avail_w - btn_w) * 0.5)
    r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + 2)
    r.ImGui_BeginDisabled(ctx, #slots >= MAX_SLOTS)
    if r.ImGui_Button(ctx, "+ Add slot", btn_w, 0) then
      local n = #slots + 1
      slots[#slots+1] = { name = string.format("Layout %02d", n), data = nil }
      any_changed = true
    end
    r.ImGui_EndDisabled(ctx)

    if any_changed then save_all(slots) end
    r.ImGui_End(ctx)
  end

  if open then
    r.defer(loop)
  else
    if r.ImGui_DestroyContext then 
      save_all(slots)
      r.ImGui_DestroyContext(ctx) 
      end
  end
end

loop()
