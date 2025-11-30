-- @provides
--   [main] Meat-Script_Make_Selected_Tracks_Children_of_Top_Selected_Track.lua
-- @description Make Selected Tracks Children of Top Selected Track
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Make Selected Tracks Children of Top Selected Track
--   - Existing hierarchy of any moved track (its own children) is preserved.
--   - Does nothing if the tracks are already direct children of the top-most track.

local r = reaper
debug_script = false

------------------------------------------------------------
-- Basic helpers
------------------------------------------------------------

local function log(s)
  if not debug_script then return end   -- <– guard ALL debug output
  r.ShowConsoleMsg(tostring(s) .. "\n")
end

local function getTrackIndex(track)
  return math.floor(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
end

local function getFolderDepth(track)
  return math.floor(r.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH"))
end

local function isSelected(track)
  return r.IsTrackSelected(track)
end

local function getTrackNameSafe(track)
  if not track then return "<nil>" end
  local _, name = r.GetTrackName(track, "")
  return name or "<no name>"
end

local function getAllTracks()
  local t = {}
  local count = r.CountTracks(0)
  for i = 0, count - 1 do
    t[#t+1] = r.GetTrack(0, i)
  end
  return t
end

------------------------------------------------------------
-- Tree build
------------------------------------------------------------

local function buildTrackTree(allTracks)
  local tree = {}
  local stack = {}
  local nodeByTrack = {}

  for i, track in ipairs(allTracks) do
    local depth = getFolderDepth(track)
    local node = {
      track         = track,
      parent        = nil,
      children      = {},
      originalIndex = i, -- 1-based in project order
      isFolderStart = (depth == 1),
      isSelected    = isSelected(track),
    }
    nodeByTrack[track] = node

    if #stack > 0 then
      node.parent = stack[#stack]
      table.insert(node.parent.children, node)
    else
      table.insert(tree, node)
    end

    if depth == 1 then
      stack[#stack+1] = node
    elseif depth < 0 then
      for _ = 1, math.abs(depth) do
        table.remove(stack, #stack)
      end
    end
  end

  return tree, nodeByTrack
end

local function gatherSelectedNodes(tree, out)
  for _, node in ipairs(tree) do
    if node.isSelected then
      out[#out+1] = node
    end
    if #node.children > 0 then
      gatherSelectedNodes(node.children, out)
    end
  end
end

------------------------------------------------------------
-- Tree helpers
------------------------------------------------------------

local function isDescendantNode(node, ancestor)
  local p = node.parent
  while p do
    if p == ancestor then return true end
    p = p.parent
  end
  return false
end

local function detachNode(tree, node)
  if node.parent then
    local siblings = node.parent.children
    for i = #siblings, 1, -1 do
      if siblings[i] == node then
        table.remove(siblings, i)
        break
      end
    end
    node.parent = nil
  else
    for i = #tree, 1, -1 do
      if tree[i] == node then
        table.remove(tree, i)
        break
      end
    end
  end
end

local function attachNode(node, newParent)
  node.parent = newParent
  table.insert(newParent.children, node)
end

-- If a node has a selected ancestor (not the anchor) that is also
-- outside the anchor hierarchy, we do not move this node separately.
local function ancestorHasSelectedOutsideAnchor(node, anchor)
  local p = node.parent
  while p do
    if p.isSelected and p ~= anchor and not isDescendantNode(p, anchor) then
      return true
    end
    p = p.parent
  end
  return false
end

------------------------------------------------------------
-- Flatten tree & assign levels
------------------------------------------------------------

local function flattenTreeWithLevels(tree, out)
  local function dfs(node, level)
    node._level = level
    out[#out+1] = node
    for _, child in ipairs(node.children) do
      dfs(child, level + 1)
    end
  end
  for _, node in ipairs(tree) do
    if not node.parent then
      dfs(node, 0)
    end
  end
end

local function reorderPhysically(finalList)
  for i, node in ipairs(finalList) do
    r.SetOnlyTrackSelected(node.track)
    r.ReorderSelectedTracks(i - 1, 0)
  end
end

-- New folder-depth writer: based purely on levels
local function applyFolderDepthsFromLevels(finalList)
  local n = #finalList
  for i, node in ipairs(finalList) do
    local cur_level  = node._level or 0
    local next_level = 0
    if i < n then
      next_level = finalList[i+1]._level or 0
    end
    local delta = next_level - cur_level
    r.SetMediaTrackInfo_Value(node.track, "I_FOLDERDEPTH", delta)
  end
end

------------------------------------------------------------
-- Selection save/restore
------------------------------------------------------------

local function saveSelection()
  local t = {}
  local cnt = r.CountSelectedTracks(0)
  for i = 0, cnt - 1 do
    t[#t+1] = r.GetSelectedTrack(0, i)
  end
  return t
end

local function restoreSelection(list)
  local total = r.CountTracks(0)
  for i = 0, total - 1 do
    r.SetTrackSelected(r.GetTrack(0, i), false)
  end
  for _, tr in ipairs(list) do
    if tr then
      r.SetTrackSelected(tr, true)
    end
  end
end

------------------------------------------------------------
-- Debug: print tree vs GetParentTrack
------------------------------------------------------------

local function printTreeWithParents(tree, label)

  log("==================================================")
  log(label)
  log("==================================================")

  local function dfs(node, level)
    local indent = string.rep("  ", level)
    local projIdx   = getTrackIndex(node.track)
    local depth     = getFolderDepth(node.track)
    local name      = getTrackNameSafe(node.track)
    local sel       = node.isSelected and "SEL" or "   "
    local flag      = node.isFolderStart and "FOLDER_START" or "NORMAL"

    local treeParent   = node.parent and getTrackNameSafe(node.parent.track) or "<root>"
    local reaperParent = r.GetParentTrack(node.track)
    local reaperParentName = reaperParent and getTrackNameSafe(reaperParent) or "<root>"

    local match = (treeParent == reaperParentName) and "MATCH" or "MISMATCH"

    log(string.format(
      "%s[%02d] depth=%d level=%d %s %s children=%d name='%s' | treeParent='%s' reaperParent='%s' -> %s",
      indent, projIdx, depth, level, sel, flag, #node.children, name,
      treeParent, reaperParentName, match
    ))

    for _, child in ipairs(node.children) do
      dfs(child, level + 1)
    end
  end

  for _, node in ipairs(tree) do
    if not node.parent then
      dfs(node, 0)
    end
  end
end

------------------------------------------------------------
-- Main
------------------------------------------------------------

local function Main()
  r.Undo_BeginBlock()
  r.ClearConsole()
  log("Make selected tracks children of top-most selected track (DEEP DEBUG, level-diff)")
  log("")

  local numSel = r.CountSelectedTracks(0)
  log("Selected tracks count: " .. tostring(numSel))

  if numSel < 2 then
    log("Not enough selected tracks. Aborting.")
    r.ShowMessageBox(
      "Select at least two tracks.\nThe top-most selected track will be the parent.",
      "Make Children of Top Selected Track",
      0
    )
    r.Undo_EndBlock("Make selected tracks children of top-most selected track (DEEP DEBUG, level-diff)", -1)
    return
  end

  -- BEFORE
  local allTracks = getAllTracks()
  local tree = buildTrackTree(allTracks)

  printTreeWithParents(tree, "BEFORE hierarchy (tree vs GetParentTrack)")

  local selectedNodes = {}
  gatherSelectedNodes(tree, selectedNodes)
  log("")
  log("Selected nodes (in tree): " .. tostring(#selectedNodes))

  if #selectedNodes < 2 then
    log("Less than 2 selected nodes in tree, abort.")
    r.Undo_EndBlock("Make selected tracks children of top-most selected track (DEEP DEBUG, level-diff)", -1)
    return
  end

  table.sort(selectedNodes, function(a, b) return a.originalIndex < b.originalIndex end)
  local anchor = selectedNodes[1]
  local anchorName = getTrackNameSafe(anchor.track)
  local anchorIdx  = getTrackIndex(anchor.track)

  log("")
  log(string.format("ANCHOR: origIndex=%d projIdx=%d name='%s'", anchor.originalIndex, anchorIdx, anchorName))

  -- Decide which nodes to move
  local toMove = {}
  for i = 2, #selectedNodes do
    local node = selectedNodes[i]
    local idx = getTrackIndex(node.track)
    local nm  = getTrackNameSafe(node.track)

    if isDescendantNode(node, anchor) then
      log(string.format("SKIP: already descendant of anchor -> projIdx=%d name='%s'", idx, nm))
    elseif ancestorHasSelectedOutsideAnchor(node, anchor) then
      log(string.format("SKIP: has selected ancestor outside anchor -> projIdx=%d name='%s'", idx, nm))
    else
      log(string.format("MOVE CANDIDATE: projIdx=%d name='%s'", idx, nm))
      toMove[#toMove+1] = node
    end
  end

  log("")
  log("Total nodes to move: " .. tostring(#toMove))

  if #toMove == 0 then
    log("Nothing to move. Exiting without changes.")
    r.Undo_EndBlock("Make selected tracks children of top-most selected track (DEEP DEBUG, level-diff)", -1)
    return
  end

  for _, node in ipairs(toMove) do
    local idx = getTrackIndex(node.track)
    local nm  = getTrackNameSafe(node.track)
    log(string.format("Reparenting projIdx=%d name='%s' under anchor '%s'", idx, nm, anchorName))
    detachNode(tree, node)
    attachNode(node, anchor)
  end

  -- Flatten + levels
  local finalOrder = {}
  flattenTreeWithLevels(tree, finalOrder)

  log("")
  log("Final flattened tree order (with levels) BEFORE applying to project:")
  for i, node in ipairs(finalOrder) do
    local idx = getTrackIndex(node.track)
    local nm  = getTrackNameSafe(node.track)
    log(string.format("  [%02d] projIdx=%d level=%d name='%s'", i, idx, node._level or 0, nm))
  end

  local savedSel = saveSelection()

  r.PreventUIRefresh(1)
  reorderPhysically(finalOrder)
  applyFolderDepthsFromLevels(finalOrder)
  restoreSelection(savedSel)
  r.PreventUIRefresh(-1)

  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()

  -- AFTER
  local allTracksAfter = getAllTracks()
  local treeAfter = buildTrackTree(allTracksAfter)
  printTreeWithParents(treeAfter, "AFTER hierarchy (tree vs GetParentTrack)")

  r.Undo_EndBlock("Make selected tracks children of top-most selected track (DEEP DEBUG, level-diff)", -1)
end

Main()
