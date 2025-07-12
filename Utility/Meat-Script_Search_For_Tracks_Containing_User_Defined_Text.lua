-- @provides
--   [main] Meat-Script_Search_For_Tracks_Containing_User_Defined_Text.lua
-- @description Search For Tracks Containing User Defined Text
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Search For Tracks Containing User Defined Text
--   - Prompts for a text fragment (case-insensitive).
--   - Tracks whose names contain the fragment are shown.
--   - If a match is a folder parent, all of its descendants are shown.
--   - If a match is a child track, every ancestor folder is shown.
--   - Folders that must be visible are un-folded.
--   - If no track matches, script aborts and shows an error.

local function add_to_set(set, track)
  if track then set[reaper.GetTrackGUID(track)] = track end
end

local function show_hierarchy_for_match(idx, show_set)
  local tr         = reaper.GetTrack(0, idx)
  local depth      = reaper.GetTrackDepth(tr)    -- indent level (0 = top) :contentReference[oaicite:0]{index=0}
  local track_cnt  = reaper.CountTracks(0)

  -- 1) Add the matched track itself
  add_to_set(show_set, tr)

  -- 2) ───── Descendants if it is a folder parent ───────────────────
  --        Walk forward until depth goes back up to—or above—
  --        the parent's own depth.
  for i = idx + 1, track_cnt - 1 do
    local t2      = reaper.GetTrack(0, i)
    local depth2  = reaper.GetTrackDepth(t2)
    if depth2 > depth then
      add_to_set(show_set, t2)
    else
      break -- left the folder subtree
    end
  end

  -- 3) ───── Ancestors chain (any match type) ───────────────────────
  local parent = reaper.GetParentTrack(tr)       -- direct parent (nil if none) :contentReference[oaicite:1]{index=1}
  while parent do
    add_to_set(show_set, parent)
    parent = reaper.GetParentTrack(parent)
  end
end

local function main()
  --------------------------------------------------------------------
  -- 1) Ask the user for search text
  --------------------------------------------------------------------
  local ok, pattern = reaper.GetUserInputs(
      "Search Tracks", 1, "Track name contains:", "")
  if not ok or pattern == "" then return end
  pattern = pattern:lower()

  --------------------------------------------------------------------
  -- 2) Find all matching track indices
  --------------------------------------------------------------------
  local matches, match_count = {}, 0
  local track_cnt = reaper.CountTracks(0)
  for i = 0, track_cnt - 1 do
    local tr      = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if (name or ""):lower():find(pattern, 1, true) then
      matches[#matches+1] = i
      match_count = match_count + 1
    end
  end

  if match_count == 0 then
    reaper.ShowMessageBox("No tracks contain:\n\n  " .. pattern,
                          "Search Tracks", 0)
    return
  end

  --------------------------------------------------------------------
  -- 3) Build a set of every track that must be shown
  --------------------------------------------------------------------
  local show_set = {}
  for _, idx in ipairs(matches) do
    show_hierarchy_for_match(idx, show_set)
  end

  --------------------------------------------------------------------
  -- 4) Apply visibility + un-fold folders + refresh
  --------------------------------------------------------------------
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for i = 0, track_cnt - 1 do
    local tr        = reaper.GetTrack(0, i)
    local guid      = reaper.GetTrackGUID(tr)
    local should_show = show_set[guid] and 1 or 0

    -- TCP / MCP visibility
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP",   should_show)
    reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", should_show)

    -- If the track must be shown *and* is a folder, ensure it is expanded
    if should_show == 1 and
       reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 then
      reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERCOMPACT", 0)
    end
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Search & Filter Tracks + Hierarchy", -1)
end

main()
