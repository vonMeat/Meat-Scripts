-- @description Track Routing Manager
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   - Lists every track that has at least one track-send. 
--   - Opens the respective I/O window when you press “I/O".
--   - Pressing 'Select' isolates those tracks in mix and track view
--   - Pressing 'Show All' unihdes all tracks in the project.

---------------------------------------------------------------------------
--  USER-TWEAKABLE CONSTANTS
---------------------------------------------------------------------------
local ROUTING_CMD          = 40293   -- Track: View I/O for current/last-touched track
local SET_LAST_TOUCHED_CMD = 40914   -- Track: Set first selected track as last-touched
local REFRESH_SEC          = 0.5
local WIDTH_WITH_ROUTING   = 420
local WIDTH_NO_ROUTING     = 300
---------------------------------------------------------------------------

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("ReaImGui extension not found (install via ReaPack).",
                        "ERROR", 0)
  return
end

---------------------------------------------------------------------------
--  ImGui setup
---------------------------------------------------------------------------
local ctx  = reaper.ImGui_CreateContext("Track Routing Manager")
local font = reaper.ImGui_CreateFont("sans-serif", 14,
                                     reaper.ImGui_FontFlags_Bold())
reaper.ImGui_Attach(ctx, font)

---------------------------------------------------------------------------
--  Helpers
---------------------------------------------------------------------------
local function trackName(track)
  local _, n = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return (n ~= "" and n) or ("Track " .. reaper.CSurf_TrackToID(track, false))
end

local function chanPairLabel(dstchan)
  if dstchan == -1 then return "(all)" end
  local pair = math.floor(dstchan / 2) + 1
  return string.format("(%d/%d)", pair*2-1, pair*2)
end

local function buildRoutingList()
  local list, tot = {}, reaper.CountTracks(0)
  for i = 0, tot-1 do
    local tr      = reaper.GetTrack(0, i)
    local numSend = reaper.GetTrackNumSends(tr, 0)
    if numSend > 0 then
      local e = { track = tr, dests = {} }
      for s = 0, numSend-1 do
        local dst    = reaper.GetTrackSendInfo_Value(tr, 0, s, "P_DESTTRACK")
        local dstCh  = reaper.GetTrackSendInfo_Value(tr, 0, s, "I_DSTCHAN")
        e.dests[#e.dests+1] = { dst, dstCh }
      end
      list[#list+1] = e
    end
  end
  return list
end

-- Unhide every track in TCP & MCP
local function unhideAllTracks()
  local tot = reaper.CountTracks(0)
  for i = 0, tot-1 do
    local tr = reaper.GetTrack(0, i)
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP",   1)
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 1)
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end


-- Open I/O window for the given track
local function openIO(track)
  reaper.Main_OnCommand(40297, 0)              -- Unselect all
  reaper.SetTrackSelected(track, true)
  reaper.Main_OnCommand(SET_LAST_TOUCHED_CMD,0)
  reaper.Main_OnCommand(ROUTING_CMD, 0)
end

-- Select sender + all its destination tracks,
-- then hide everything else (TCP & MCP)
local function selectSenderAndDests(entry)
  reaper.Undo_BeginBlock()

  -- 1) Select the relevant tracks
  reaper.Main_OnCommand(40297, 0)              -- Unselect all
  reaper.SetTrackSelected(entry.track, true)
  for _, d in ipairs(entry.dests) do
    reaper.SetTrackSelected(d[1], true)
  end

  -- 2) Show only the selected tracks
  local tot = reaper.CountTracks(0)
  for i = 0, tot-1 do
    local tr     = reaper.GetTrack(0, i)
    local showIt = reaper.IsTrackSelected(tr) and 1 or 0
    -- TCP
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP",   showIt)
    -- MCP
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", showIt)
  end
  reaper.TrackList_AdjustWindows(false)  -- refresh TCP/MCP
  reaper.UpdateArrange()

  reaper.Undo_EndBlock("Track Routing Manager: show only selected tracks", -1)
end

---------------------------------------------------------------------------
--  Main loop
---------------------------------------------------------------------------
local routingList, nextRefresh, firstSizeSet = {}, 0, false

local function frame()
  -- refresh list
  local t = reaper.time_precise()
  if t >= nextRefresh then
    routingList  = buildRoutingList()
    nextRefresh  = t + REFRESH_SEC
  end

  -- window first-open size
  if not firstSizeSet then
    local w = (#routingList > 0) and WIDTH_WITH_ROUTING or WIDTH_NO_ROUTING
    reaper.ImGui_SetNextWindowSize(ctx, w, 0,
                                   reaper.ImGui_Cond_FirstUseEver())
    firstSizeSet = true
  end

  -- draw
  local vis, open = reaper.ImGui_Begin(ctx, "Track Routing Manager", true)
    -- ── MASTER header ───────────────────────────────────────────────
  local master = reaper.GetMasterTrack(0)
  local ch     = reaper.GetMediaTrackInfo_Value(master, "I_NCHAN") -- 2 = stereo, 4 = quad …

  reaper.ImGui_Text(ctx, ("MASTER (%d track%s)"):format(ch,
                          ch ~= 1 and "s" or ""))

  reaper.ImGui_SameLine(ctx, nil, 8)
  if reaper.ImGui_Button(ctx, "Show All") then
    unhideAllTracks()
  end

  reaper.ImGui_Separator(ctx)        -- spacer line
  reaper.ImGui_Dummy(ctx, 0, 4)      -- extra vertical breathing room
  if vis then
    for _, e in ipairs(routingList) do
      local tr = e.track
      reaper.ImGui_Text(ctx, trackName(tr))

      -- I/O button
      reaper.ImGui_SameLine(ctx, nil, 8)
      if reaper.ImGui_Button(ctx, ("I/O##%p"):format(tr)) then
        openIO(tr)
      end

      -- Select button
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, ("Select##%p"):format(tr)) then
        selectSenderAndDests(e)
      end

      -- destination list
      for _, d in ipairs(e.dests) do
        local dstTr, dstCh = d[1], d[2]
        reaper.ImGui_Text(ctx,
          " |  - " .. trackName(dstTr) .. " " .. chanPairLabel(dstCh))
      end
      reaper.ImGui_Dummy(ctx, 0, 8)
    end

    if #routingList == 0 then
      reaper.ImGui_Text(ctx, "(No track-to-track sends in this project.)")
    end
    reaper.ImGui_End(ctx)
  end

  if open then
    reaper.defer(frame)
  else
    if reaper.ImGui_DestroyContext then
      reaper.ImGui_DestroyContext(ctx)
    end
  end
end

frame()
