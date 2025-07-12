-- @provides
--   [main] Meat-Script_Insert_Empty_Space_Between_Selected_Media_Items.lua
-- @description Insert Silence Between Selected Media Items
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Insert Silence Between Selected Media Items
--   - For each track with 2+ selected items, insert X seconds of silence between them.
--   - The leftmost item on each track stays anchored.\
--   - Per track, NOT additive.

-- Prompt user for silence duration
local retval, input = reaper.GetUserInputs("Insert Silence", 1, "Silence Between Items (seconds):", "1.0")
if not retval then return end

local silence = tonumber(input)
if not silence or silence < 0 then
  reaper.ShowMessageBox("Please enter a valid positive number.", "Invalid Input", 0)
  return
end

-- Collect selected items, group by track
local num_items = reaper.CountSelectedMediaItems(0)
if num_items < 2 then
  reaper.ShowMessageBox("Select at least two items across tracks.", "Too Few Items", 0)
  return
end

local track_groups = {}

for i = 0, num_items - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local track = reaper.GetMediaItemTrack(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  local track_id = tostring(track) -- Unique key for the track
  if not track_groups[track_id] then
    track_groups[track_id] = {
      track = track,
      items = {}
    }
  end

  table.insert(track_groups[track_id].items, {
    item = item,
    position = pos,
    length = len
  })
end

-- Begin edit
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

for _, group in pairs(track_groups) do
  local items = group.items
  if #items < 2 then
    goto continue
  end

  -- Sort items on this track by position
  table.sort(items, function(a, b) return a.position < b.position end)

  local next_pos = items[1].position + items[1].length + silence
  for i = 2, #items do
    reaper.SetMediaItemInfo_Value(items[i].item, "D_POSITION", next_pos)
    next_pos = next_pos + items[i].length + silence
  end

  ::continue::
end

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Insert Silence Between Selected Items (Per Track)", -1)
reaper.UpdateArrange()
