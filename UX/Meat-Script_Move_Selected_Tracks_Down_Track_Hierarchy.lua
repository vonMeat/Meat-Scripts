-- @provides
--   [main] Meat-Script_Move_Selected_Tracks_Down_Track_Hierarchy.lua
-- @description Move Selected Tracks Down Track Hierarchy
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Move Selected Tracks Down Track Hierarchy
--   - Recommended to install both this script and 'Move Selected Tracks Up Track Hierarchy'.
--   - Recommended to assign a shortcut key. 
--   - Moves and selected number of tracks down one lane.
--   - Will move into or out of parents tracks when being moved down.

local r = reaper

------------------------------------------------------------
-- Basic helpers
------------------------------------------------------------

local function getFolderDepth(track)
  return math.floor(r.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH"))
end

local function isSelected(track)
  return r.IsTrackSelected(track)
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
-- Build tree from current project
------------------------------------------------------------

local function buildTrackTree(allTracks)
  local tree = {}
  local stack = {}

  for i, track in ipairs(allTracks) do
    local depth = getFolderDepth(track)

    local node = {
      track         = track,
      parent        = nil,
      children      = {},
      originalIndex = i,     -- project order, 1-based
      isSelected    = isSelected(track),
    }

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

  return tree
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
-- Tree manipulation helpers
------------------------------------------------------------

local function indexOfChild(parent, child)
  local children = parent.children
  for i = 1, #children do
    if children[i] == child then
      return i
    end
  end
  return nil
end

local function indexOfRoot(tree, node)
  for i = 1, #tree do
    if tree[i] == node then
      return i
    end
  end
  return nil
end

-- Move a node "down":
-- - If next sibling/root is a folder with children: move into it as first child.
-- - Else, swap with next sibling/root.
-- - If node is the last child in a folder: demote out, inserting below parent.
local function moveNodeDown(tree, node)
  local parent = node.parent

  if parent then
    local idx = indexOfChild(parent, node)
    if not idx then return end

    local childCount = #parent.children

    if idx < childCount then
      -- There is a next sibling
      local nextNode = parent.children[idx + 1]
      if #nextNode.children > 0 then
        -- Move into next folder as first child
        table.remove(parent.children, idx)
        node.parent = nextNode
        table.insert(nextNode.children, 1, node)
      else
        -- Swap with next sibling
        parent.children[idx + 1], parent.children[idx] =
          parent.children[idx], parent.children[idx + 1]
      end
    else
      -- idx == childCount: last child, demote out of folder
      local grandparent = parent.parent

      table.remove(parent.children, idx)
      node.parent = nil

      if grandparent then
        local gpIdx = indexOfChild(grandparent, parent)
        if gpIdx then
          table.insert(grandparent.children, gpIdx + 1, node)
          node.parent = grandparent
        else
          table.insert(tree, node)
        end
      else
        local rootIdx = indexOfRoot(tree, parent)
        if rootIdx then
          table.insert(tree, rootIdx + 1, node)
        else
          table.insert(tree, node)
        end
      end
    end
  else
    -- Root node
    local idx = indexOfRoot(tree, node)
    if not idx or idx == #tree then return end

    local nextRoot = tree[idx + 1]
    if #nextRoot.children > 0 then
      -- Move into next root folder as first child
      table.remove(tree, idx)
      node.parent = nextRoot
      table.insert(nextRoot.children, 1, node)
    else
      -- Swap with next root
      tree[idx + 1], tree[idx] = tree[idx], tree[idx + 1]
    end
  end
end

------------------------------------------------------------
-- Flatten tree + compute indentation levels
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

local function reorderPhysically(list)
  for i, node in ipairs(list) do
    r.SetOnlyTrackSelected(node.track)
    r.ReorderSelectedTracks(i - 1, 0)
  end
end

local function applyFolderDepthsFromLevels(list)
  local n = #list
  for i, node in ipairs(list) do
    local lvl  = node._level or 0
    local next = (i < n) and (list[i+1]._level or 0) or 0
    r.SetMediaTrackInfo_Value(node.track, "I_FOLDERDEPTH", next - lvl)
  end
end

------------------------------------------------------------
-- Selection helpers
------------------------------------------------------------

local function saveSelection()
  local t = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do
    t[#t+1] = r.GetSelectedTrack(0, i)
  end
  return t
end

local function restoreSelection(t)
  for i = 0, r.CountTracks(0) - 1 do
    r.SetTrackSelected(r.GetTrack(0, i), false)
  end
  for _, tr in ipairs(t) do
    if tr then r.SetTrackSelected(tr, true) end
  end
end

------------------------------------------------------------
-- Main
------------------------------------------------------------

local function Main()
  local selCount = r.CountSelectedTracks(0)
  if selCount == 0 then return end

  r.Undo_BeginBlock()

  local all = getAllTracks()
  local tree = buildTrackTree(all)

  local selectedNodes = {}
  gatherSelectedNodes(tree, selectedNodes)
  if #selectedNodes == 0 then
    r.Undo_EndBlock("Move tracks down", -1)
    return
  end

  -- Process from bottom to top so they do not leapfrog each other
  table.sort(selectedNodes, function(a, b) return a.originalIndex > b.originalIndex end)

  for _, node in ipairs(selectedNodes) do
    moveNodeDown(tree, node)
  end

  local final = {}
  flattenTreeWithLevels(tree, final)

  local savedSel = saveSelection()

  r.PreventUIRefresh(1)
  reorderPhysically(final)
  applyFolderDepthsFromLevels(final)
  restoreSelection(savedSel)
  r.PreventUIRefresh(-1)

  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  r.Undo_EndBlock("Move selected tracks down (folder-aware)", -1)
end

Main()
