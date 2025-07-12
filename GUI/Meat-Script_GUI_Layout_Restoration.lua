-- @provides
--   [main] Meat-Script_GUI_Layout_Restoration.lua
-- @description Layout Restoration
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Layout Restoration
--   - Store up to 10 project layouts. Top row saves, bottom row loads.
-- @extrequires ReaImGui

-----------------------------------------------------------------
-- user-tweakable ------------------------------------------------
-----------------------------------------------------------------
local INIT_W, INIT_H = 400, 80          -- initial window size (px)
local EXT_NAMESPACE  = "RS_VIS_LAYOUT"  -- key under which data is saved
-----------------------------------------------------------------

local r = reaper
if not r.ImGui_CreateContext then
  r.ShowMessageBox("ReaImGui extension not found (install via ReaPack).", "ERROR", 0)
  return
end

-------------------------------------------------
-- data
-------------------------------------------------
local SLOT_COUNT   = 10
local layouts      = {}                 -- [slot] = { [guid]= {tcp=0/1,mcp=0/1} }
local ctx          = r.ImGui_CreateContext("Layout Visibility")
local win_flags    = r.ImGui_WindowFlags_NoResize()
local proj         = 0                  -- current project handle (0 = active)

-------------------------------------------------
-- persistence helpers
-------------------------------------------------
local function serialise(tbl)
  local out = {}
  for guid,vis in pairs(tbl) do
    out[#out+1] = table.concat({guid, vis.tcp, vis.mcp}, ",")
  end
  return table.concat(out, "\n")
end

local function deserialise(str)
  local t = {}
  for line in str:gmatch("[^\n]+") do
    local g,tcp,mcp = line:match("([^,]+),([^,]+),([^,]+)")
    if g then t[g] = {tcp=tonumber(tcp), mcp=tonumber(mcp)} end
  end
  return t
end

local function persist_slot(slot)
  local key = ("slot%d"):format(slot)
  local lay = layouts[slot]
  if lay then
    r.SetProjExtState(proj, EXT_NAMESPACE, key, serialise(lay))
  else
    r.SetProjExtState(proj, EXT_NAMESPACE, key, "")          -- wipe if nil
  end
end

local function load_all_slots()
  for s=1,SLOT_COUNT do
    local ok, str = r.GetProjExtState(proj, EXT_NAMESPACE, ("slot%d"):format(s))
    if ok == 1 and str ~= "" then layouts[s] = deserialise(str) end
  end
end
load_all_slots()

-------------------------------------------------
-- store / restore
-------------------------------------------------
local function guid(tr) return r.GetTrackGUID(tr) end

local function store(slot)
  layouts[slot] = {}
  for i=0, r.CountTracks(0)-1 do
    local tr = r.GetTrack(0,i)
    layouts[slot][guid(tr)] =
      { tcp = r.GetMediaTrackInfo_Value(tr,"B_SHOWINTCP"),
        mcp = r.GetMediaTrackInfo_Value(tr,"B_SHOWINMIXER") }
  end
  persist_slot(slot)
end

local function restore(slot)
  local lay = layouts[slot]; if not lay then return end
  r.Undo_BeginBlock()
  for i=0, r.CountTracks(0)-1 do
    local tr = r.GetTrack(0,i)
    local s  = lay[guid(tr)]
    if s then
      r.SetMediaTrackInfo_Value(tr,"B_SHOWINTCP", s.tcp)
      r.SetMediaTrackInfo_Value(tr,"B_SHOWINMIXER", s.mcp)
    end
  end
  r.TrackList_AdjustWindows(false)
  r.Undo_EndBlock(("Restore visibility layout %d"):format(slot), -1)
end

-------------------------------------------------
-- GUI
-------------------------------------------------
local function row(label, prefix, action, restore_row)
  r.ImGui_Text(ctx, label); r.ImGui_SameLine(ctx, nil, 8)
  for i=1,SLOT_COUNT do
    local id = ("%s%d"):format(prefix,i)
    local disabled = restore_row and not layouts[i]
    if disabled then r.ImGui_BeginDisabled(ctx) end
    if r.ImGui_Button(ctx, tostring(i).."##"..id, 28, 0) then action(i) end
    if disabled then r.ImGui_EndDisabled(ctx) end
    if i<SLOT_COUNT then r.ImGui_SameLine(ctx, nil, 4) end
  end
end

local function loop()
  r.ImGui_SetNextWindowSize(ctx, INIT_W, INIT_H, r.ImGui_Cond_FirstUseEver())
  local visible,open = r.ImGui_Begin(ctx, "Track-Visibility Layouts", true, win_flags)
  if visible then
    row("Save :  ", "save",  store,   false)
    row("Restore:", "rest",  restore, true)
    r.ImGui_End(ctx)
  end
  if open then
    r.defer(loop)
  else
    -- safe-destroy: only call if the function exists (older ReaImGui builds lack it)
    if r.ImGui_DestroyContext then r.ImGui_DestroyContext(ctx) end
  end
end
loop()
